import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/product_catalog.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';

/// DAS-160: a medicine sold loose is sold in tablets only: the picker counts
/// tablets at a tablet's price, the review list and the server are told so,
/// and a whole-only item keeps today's sheet with a note.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const _strip = {
  'units_per_pack': 10,
  'sold_loose': true,
  'unit_kind': 'tablet',
  'units_on_hand': 45,
  'unit_mrp': 10.0,
};

const _bottle = {
  'units_per_pack': null,
  'sold_loose': false,
  'unit_kind': null,
  'units_on_hand': null,
  'unit_mrp': null,
};

MockClient _server(Map<String, Object?> loose, {void Function(Map<String, dynamic>)? onSale}) => MockClient((req) async {
      if (req.url.path == '/inventory/products') {
        return _json([
          {'id': 1, 'name': 'Paracetamol 650', 'quantity_on_hand': 4.5, 'mrp': 100, ...loose},
        ]);
      }
      if (req.url.path == '/inventory/products/1') {
        return _json({
          'id': 1,
          'name': 'Paracetamol 650',
          'total_quantity': 4.5,
          ...loose,
          'batches': [
            {
              'id': 7,
              'batch_no': 'B2291',
              'expiry_date': '2027-08-31',
              'quantity_on_hand': 4.5,
              'mrp': 100,
              'gst_pct': 12,
              'is_expired': false,
              ...loose,
            },
          ],
        });
      }
      if (req.url.path == '/sales' && req.method == 'POST') {
        onSale?.call(jsonDecode(req.body) as Map<String, dynamic>);
        return _json({'sale_id': 5, 'sale_no': 'S-0005', 'grand_total': 200.0});
      }
      return http.Response('no', 404);
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
  });
  tearDown(() => ApiClient.instance.token = null);

  Future<void> openPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SalesScreen())));
    await ProductCatalog.instance.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
  }

  /// Add (the sheet closes), clear the "Added …" snackbar that sits over the
  /// cart button, and open the cart.
  Future<void> addAndOpenCart(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('View cart'));
    await tester.pumpAndSettle();
  }

  testWidgets('a strip sold loose: tablets only, at a tablet\'s price, and the server is told "loose"', (tester) async {
    Map<String, dynamic>? sale;
    await http.runWithClient(() async {
      await openPicker(tester);
      expect(find.text('Available: 45 tablets'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Tablets'), findsOneWidget);
      expect(find.text('Price a tablet (incl. GST)'), findsOneWidget);
      expect(find.widgetWithText(TextField, '10.00'), findsOneWidget, reason: 'MRP ₹100 ÷ 10');
      expect(find.text('Strip of 10, so 2 strips = 20 tablets'), findsOneWidget);
      expect(find.text('Strips'), findsNothing, reason: 'the user chose tablets only, no switch');

      await tester.enterText(find.widgetWithText(TextField, 'Tablets'), '20');
      await tester.pump();
      await addAndOpenCart(tester);
      await tester.pumpAndSettle();
      expect(find.byType(SaleReviewScreen), findsOneWidget);
      expect(find.text('Paracetamol 650 × 20 tablets'), findsOneWidget);

      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
    }, () => _server(_strip, onSale: (b) => sale = b));
    final line = (sale!['line_items'] as List).single as Map<String, dynamic>;
    expect(line['unit'], 'loose');
    expect(line['qty'], 20.0);
    expect(line['rate'], 10.0);
  });

  testWidgets('a price above MRP ÷ 10 is allowed: the MRP is sometimes corrected later', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.enterText(find.widgetWithText(TextField, '10.00'), '12');
      await tester.pump();
      expect(find.textContaining('Up to'), findsNothing);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add')).onPressed, isNotNull);
    }, () => _server(_strip));
  });

  testWidgets('part of a tablet is refused before it reaches the server', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Tablets'), '2.5');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Enter a whole number of tablets'), findsOneWidget);
      expect(find.textContaining('View cart'), findsNothing);
    }, () => _server(_strip));
  });

  testWidgets('more tablets than the batch holds gets the note in tablets', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Tablets'), '50');
      await tester.pump();
      expect(find.text('Only 45 tablets in inventory. The item is still billed; only this note stays off the bill.'), findsOneWidget);
    }, () => _server(_strip));
  });

  testWidgets('a whole-only item keeps today\'s sheet, with a note, and sends no unit', (tester) async {
    Map<String, dynamic>? sale;
    await http.runWithClient(() async {
      await openPicker(tester);
      expect(find.text('Available: 5'), findsOneWidget, reason: '4.5 packs, rounded as before');
      expect(find.text("Sold whole only, at the pack's MRP"), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Qty'), findsOneWidget);
      expect(find.widgetWithText(TextField, '100.00'), findsOneWidget);
      await addAndOpenCart(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
    }, () => _server(_bottle, onSale: (b) => sale = b));
    final line = (sale!['line_items'] as List).single as Map<String, dynamic>;
    expect(line.containsKey('unit'), isFalse);
  });

  testWidgets('the cart line editor counts tablets too and refuses part of one', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final cart = [
      CartEntry(
          productBatchId: 7,
          productName: 'Paracetamol 650',
          batchNo: 'B2291',
          qty: 20,
          rate: 10,
          gstPct: 12,
          available: 45,
          loose: true,
          unitKind: 'tablet'),
    ];
    await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: cart)));
    await tester.tap(find.text('Paracetamol 650 × 20 tablets'));
    await tester.pumpAndSettle();
    expect(find.text('Batch B2291 · 45 tablets in stock'), findsOneWidget);
    expect(find.text('Price a tablet (incl. GST)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '20'), '2.5');
    await tester.pump();
    expect(find.text('Enter a whole number of tablets'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
  });
}
