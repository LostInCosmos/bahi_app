import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

/// Quality pass: a detail screen whose load failed offers Try again, and
/// Try again loads it.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
  });
  tearDown(() => ApiClient.instance.token = null);

  testWidgets('product detail: a failed load shows the reason and Try again, which loads it', (tester) async {
    var fail = true;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: ProductDetailScreen(productId: 1)));
      await tester.pumpAndSettle();
      expect(find.text('Could not load product: Server error (502)'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Batch B1'), findsOneWidget);
    }, () => MockClient((req) async {
          if (req.url.path != '/inventory/products/1') return http.Response('no', 404);
          if (fail) return http.Response('<html>502</html>', 502);
          return _json({
            'id': 1,
            'name': 'Dolo 650',
            'total_quantity': 3,
            'batches': [
              {'id': 7, 'batch_no': 'B1', 'quantity_on_hand': 3, 'gst_pct': 12, 'is_expired': false, 'mrp': 30},
            ],
          });
        }));
  });
}
