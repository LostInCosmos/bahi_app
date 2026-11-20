import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

/// DAS-201: a batch card's price is its Net rate, right under the MRP row; the
/// printed rate is not shown, and a batch with no purchase rate shows a dash.

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

MockClient _server() => MockClient((req) async {
      if (req.url.path == '/inventory/products/1') {
        return _json({
          'id': 1,
          'name': 'Paracetamol 500mg',
          'total_quantity': 50,
          'batches': [
            {
              'id': 7,
              'batch_no': 'B2231',
              'expiry_date': '2027-03-31',
              'quantity_on_hand': 30,
              'mrp': 20,
              'gst_pct': 5,
              'is_expired': false,
              'net_rate': 9.0,
              'rate': 12.0,
              'discount_pct': 10,
              'free_qty': 2,
              'free_scheme': '10+2',
              'vendor_name': 'ACME Pharma',
              'invoice_no': 'A-1042',
            },
            {
              'id': 8,
              'batch_no': 'H-01',
              'expiry_date': '2027-01-31',
              'quantity_on_hand': 20,
              'mrp': 20,
              'gst_pct': 5,
              'is_expired': false,
            },
          ],
        });
      }
      if (req.url.path == '/inventory/products') return _json([]);
      return http.Response('no', 404);
    });

void main() {
  setUp(() => ApiClient.instance.token =
      'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s');
  tearDown(() => ApiClient.instance.token = null);

  testWidgets(
      'Net rate replaces the printed rate; a batch without one shows a dash',
      (tester) async {
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(390 * 2, 1800 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: ProductDetailScreen(productId: 1)));
      await tester.pumpAndSettle();

      expect(find.text('Net rate: ₹9.00'), findsOneWidget);
      expect(find.text('Net rate: —'), findsOneWidget);
      // The scheme stays; the printed "Rate ₹12.00" is gone.
      expect(find.text('10% off · 2 free (10+2)'), findsOneWidget);
      expect(find.textContaining('Rate ₹12'), findsNothing);
      expect(find.textContaining('Rate 12'), findsNothing);

      // Net rate sits under the MRP row, above GST.
      final mrp = tester.getTopLeft(find.text('MRP: ₹20.00').first).dy;
      final net = tester.getTopLeft(find.text('Net rate: ₹9.00')).dy;
      final gst = tester.getTopLeft(find.text('GST: 5%').first).dy;
      expect(mrp < net && net < gst, isTrue);
    }, _server);
  });
}
