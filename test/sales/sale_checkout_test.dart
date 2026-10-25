import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';
import 'package:gst_bill_app/features/sales/models/sale_totals.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_receipt_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';

/// DAS-111: the price is GST-inclusive, a discount can be taken off an item or
/// the whole sale, and the receipt says what was taken off and what GST the
/// total includes.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

List<CartEntry> _cart() => [
      CartEntry(
        productBatchId: 1,
        productName: 'Paracetamol 500mg',
        batchNo: 'B12',
        qty: 2,
        rate: 100,
        gstPct: 12,
        discount: const Discount(DiscountKind.percentage, 10),
      ),
      CartEntry(productBatchId: 2, productName: 'Cough Syrup 100ml', batchNo: 'C7', qty: 1, rate: 85, gstPct: 12),
    ];

void main() {
  setUp(() => ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s');
  tearDown(() => ApiClient.instance.token = null);

  /// A phone tall enough that the whole checkout is built (the list is lazy).
  void tallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  testWidgets('checkout: a sale at MRP totals exactly MRP, with no GST added on top', (tester) async {
    tallPhone(tester);
    final cart = [CartEntry(productBatchId: 1, productName: 'Dolo', qty: 2, rate: 100, gstPct: 12)];
    await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: cart)));
    expect(find.text('₹200.00'), findsNWidgets(2), reason: 'the line and the total');
    expect(find.text('Includes GST ₹21.42'), findsOneWidget);
    expect(find.text('Items'), findsNothing, reason: 'nothing was taken off, so no breakdown');
  });

  testWidgets('checkout: item and whole-sale discounts, as typed, change the total and the GST inside it', (tester) async {
    tallPhone(tester);
    await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: _cart())));
    expect(find.text('10% off'), findsOneWidget);
    expect(find.text('₹180.00'), findsOneWidget, reason: 'the discounted line');

    await tester.enterText(find.widgetWithText(TextField, 'Discount on whole sale'), '15');
    await tester.pump();
    expect(find.text('₹285.00'), findsOneWidget);
    expect(find.text('−₹20.00'), findsOneWidget);
    expect(find.text('−₹15.00'), findsOneWidget);
    expect(find.text('₹250.00'), findsOneWidget);
    expect(find.text('Includes GST ₹26.80'), findsOneWidget);

    // Switching to % re-reads the same number: 15% of the 265 left.
    await tester.tap(find.text('%').last);
    await tester.pump();
    expect(find.text('−₹39.75'), findsOneWidget);
    expect(find.text('₹225.25'), findsOneWidget);
  });

  testWidgets('checkout: a discount bigger than the sale is refused and cannot be completed', (tester) async {
    tallPhone(tester);
    await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: _cart())));
    await tester.enterText(find.widgetWithText(TextField, 'Discount on whole sale'), '400');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('More than the sale (₹265.00)'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('complete sale sends each discount as typed and the rate as the price', (tester) async {
    tallPhone(tester);
    Map<String, dynamic>? body;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: _cart())));
      await tester.enterText(find.widgetWithText(TextField, 'Discount on whole sale'), '15');
      await tester.pump();
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
    }, () => MockClient((req) async {
          if (req.url.path == '/sales' && req.method == 'POST') {
            body = jsonDecode(req.body) as Map<String, dynamic>;
            return _json({'sale_id': 5, 'sale_no': 'S-0005', 'grand_total': 250.0});
          }
          return http.Response('no', 404);
        }));
    expect(body!['discount'], {'type': 'amount', 'value': 15.0});
    expect(body!['allow_oversell'], isTrue, reason: 'DAS-111: the shopkeeper was told on the phone');
    final lines = body!['line_items'] as List;
    expect(lines[0], {
      'product_batch_id': 1,
      'qty': 2.0,
      'rate': 100.0,
      'discount': {'type': 'percentage', 'value': 10.0},
    });
    expect(lines[1], {'product_batch_id': 2, 'qty': 1.0, 'rate': 85.0}, reason: 'no discount key when none was typed');
  });

  testWidgets('receipt: each item\'s discount, the whole-sale one, and the GST the total includes', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: SaleReceiptScreen(saleId: 5)));
      await tester.pumpAndSettle();
    }, () => MockClient((req) async => _json({
          'id': 5,
          'sale_no': 'S-0005',
          'sale_date': '2026-10-24',
          'buyer_name': null,
          'buyer_gstin': null,
          'subtotal': 223.22,
          'total_cgst': 13.39,
          'total_sgst': 13.39,
          'grand_total': 250.0,
          'discount_amount': 15.0,
          'total_discount': 35.0,
          'line_items': [
            {
              'product_name': 'Paracetamol 500mg',
              'qty': 2,
              'rate': 100,
              'gst_pct': 12,
              'cgst_amount': 9.16,
              'sgst_amount': 9.16,
              'line_amount': 200,
              'discount_amount': 20,
              'sale_discount_share': 9,
            },
            {
              'product_name': 'Cough Syrup 100ml',
              'qty': 1,
              'rate': 85,
              'gst_pct': 12,
              'cgst_amount': 4.23,
              'sgst_amount': 4.23,
              'line_amount': 85,
              'discount_amount': 0,
              'sale_discount_share': 6,
            },
          ],
        })));
    expect(find.text('Discount −₹20.00'), findsOneWidget, reason: 'under the item that has one');
    expect(find.text('₹285.00'), findsOneWidget);
    expect(find.text('−₹15.00'), findsOneWidget);
    expect(find.text('Total paid'), findsOneWidget);
    expect(find.text('₹250.00'), findsOneWidget);
    expect(find.text('Includes GST ₹26.78 (CGST ₹13.39 + SGST ₹13.39)'), findsOneWidget);
  });

  testWidgets('receipt of a sale from before discounts: no discount rows, still says what GST is inside', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: SaleReceiptScreen(saleId: 1)));
      await tester.pumpAndSettle();
    }, () => MockClient((req) async => _json({
          'id': 1,
          'sale_no': 'S-0001',
          'sale_date': '2026-10-01',
          'subtotal': 178.58,
          'total_cgst': 10.71,
          'total_sgst': 10.71,
          'grand_total': 200.0,
          'line_items': [
            {
              'product_name': 'Dolo',
              'qty': 2,
              'rate': 100,
              'gst_pct': 12,
              'cgst_amount': 10.71,
              'sgst_amount': 10.71,
              'line_amount': 200,
            },
          ],
        })));
    expect(find.textContaining('Discount'), findsNothing);
    expect(find.text('Items'), findsNothing);
    expect(find.text('Includes GST ₹21.42 (CGST ₹10.71 + SGST ₹10.71)'), findsOneWidget);
  });
}
