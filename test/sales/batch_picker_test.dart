import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/product_catalog.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';

/// DAS-111: the sale screen's batch picker. The price is GST-inclusive and
/// prefilled from the batch's MRP; a sale with no price is refused; an item can
/// carry a discount, as ₹ or %, shown live and refused when it is too big.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _batch({double? mrp = 100}) => {
      'id': 7,
      'batch_no': 'B12',
      'expiry_date': '2027-03-01',
      'quantity_on_hand': 40,
      'mrp': mrp,
      'gst_pct': 12,
      'is_expired': false,
    };

MockClient _server({double? mrp = 100}) => MockClient((req) async {
      if (req.url.path == '/inventory/products') {
        return _json([
          {'id': 1, 'name': 'Paracetamol 500mg', 'quantity_on_hand': 40, 'mrp': mrp},
        ]);
      }
      if (req.url.path == '/inventory/products/1') {
        return _json({
          'id': 1,
          'name': 'Paracetamol 500mg',
          'total_quantity': 40,
          'batches': [_batch(mrp: mrp)],
        });
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

  testWidgets('the price is GST-inclusive, prefilled with the MRP, and a discount shows its line total live', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      expect(find.text('Price (incl. GST)'), findsOneWidget);
      expect(find.widgetWithText(TextField, '100.00'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, '1'), '2');
      await tester.enterText(find.widgetWithText(TextField, 'Discount on this item'), '10');
      await tester.pump();
      expect(find.text('Line total ₹180.00  (₹20.00 off)'), findsOneWidget);

      await tester.tap(find.text('₹').last);
      await tester.pump();
      expect(find.text('Line total ₹190.00  (₹10.00 off)'), findsOneWidget, reason: '10 as rupees, not percent');
    }, () => _server());
  });

  testWidgets('a discount above the line is refused and Add is off', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.tap(find.text('₹').last);
      await tester.enterText(find.widgetWithText(TextField, 'Discount on this item'), '250');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('More than the line (₹100.00)'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add')).onPressed, isNull);
    }, () => _server());
  });

  testWidgets('a blank or zero price is refused at Add, naming what to enter', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.enterText(find.widgetWithText(TextField, '100.00'), '');
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a price above ₹0'), findsOneWidget);
      expect(find.byType(SaleReviewScreen), findsNothing);
    }, () => _server());
  });

  testWidgets('a batch with no MRP starts with an empty price and cannot be added until one is typed', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a price above ₹0'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Price (incl. GST)'), '60');
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a price above ₹0'), findsNothing);
    }, () => _server(mrp: null));
  });
}
