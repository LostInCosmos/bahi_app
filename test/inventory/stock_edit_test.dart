import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/inventory_api.dart';
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

/// DAS-172: the shop corrects a product's stock count from its detail page,
/// in tablets when sold loose and packs otherwise; the server keeps the record
/// and the page shows it. An old server (no `stock_edits`) shows no button.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Server {
  final bool canEdit;
  final bool loose;
  final List<Map<String, dynamic>> patches = [];
  int failStatus = 0;
  Map<String, dynamic>? failWith;
  double quantity;

  _Server({this.canEdit = true, this.loose = false, this.quantity = 3});

  Map<String, Object?> get _units => loose
      ? {'units_per_pack': 10, 'sold_loose': true, 'unit_kind': 'tablet', 'units_on_hand': (quantity * 10).round(), 'unit_mrp': 10.0}
      : {'units_per_pack': null, 'sold_loose': false, 'unit_kind': null, 'units_on_hand': null, 'unit_mrp': null};

  MockClient get client => MockClient((req) async {
        if (req.url.path == '/inventory/products/1' && req.method == 'GET') {
          return _json({
            'id': 1,
            'name': 'Paracetamol 650',
            'total_quantity': quantity,
            ..._units,
            'batches': [
              {
                'id': 7,
                'batch_no': 'B12',
                'expiry_date': '2027-03-01',
                'quantity_on_hand': quantity,
                'mrp': 100,
                'gst_pct': 12,
                'is_expired': false,
                ..._units,
              },
            ],
            if (canEdit)
              'stock_edits': [
                for (final p in patches.reversed)
                  {'id': 1, 'from': 3, 'to': p['quantity_on_hand'] ?? (p['units_on_hand'] as num) / 10, 'unit': p.containsKey('units_on_hand') ? 'loose' : 'pack', 'at': '2026-11-05T14:00:00Z'},
              ],
          });
        }
        if (req.url.path == '/inventory/products/1/stock' && req.method == 'PATCH') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          patches.add(body);
          if (failStatus != 0) return _json(failWith ?? {'detail': 'no'}, failStatus);
          final packs = body.containsKey('units_on_hand') ? (body['units_on_hand'] as num) / 10 : body['quantity_on_hand'] as num;
          quantity = packs.toDouble();
          return _json({
            'product_id': 1,
            'quantity_on_hand': packs,
            'units_on_hand': loose ? (packs * 10).round() : null,
            'edit': {'id': 1, 'from': 3, 'to': packs, 'unit': body.containsKey('units_on_hand') ? 'loose' : 'pack', 'at': '2026-11-05T14:00:00Z'},
          });
        }
        if (req.url.path == '/inventory/products') return _json([]);
        return http.Response('no', 404);
      });
}

void main() {
  setUp(() => ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s');
  tearDown(() => ApiClient.instance.token = null);

  Future<void> open(WidgetTester tester, _Server server, Future<void> Function() body) =>
      http.runWithClient(() async {
        tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(const MaterialApp(home: ProductDetailScreen(productId: 1)));
        await tester.pumpAndSettle();
        await body();
      }, () => server.client);

  testWidgets('an old server (no stock_edits): no Edit stock button', (tester) async {
    await open(tester, _Server(canEdit: false), () async {
      expect(find.byKey(const ValueKey('edit-stock')), findsNothing);
    });
  });

  testWidgets('packs: the count is sent as quantity_on_hand, the page reloads and lists the correction', (tester) async {
    final server = _Server();
    await open(tester, server, () async {
      expect(find.text('3 units total, across 1 batch'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-stock')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '3'), findsOneWidget, reason: 'prefilled with the count now');
      expect(find.text('Packs in stock'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('stock-count')), '5');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(server.patches.single, {'quantity_on_hand': 5});
      expect(find.text('5 units total, across 1 batch'), findsOneWidget);
      expect(find.text('Stock corrections'), findsOneWidget);
      expect(find.text('3 → 5'), findsOneWidget);
      expect(find.text('05 Nov 2026'), findsOneWidget);
      expect(find.text('Stock saved: 5 packs'), findsOneWidget);
    });
  });

  testWidgets('tablets: a loose product is counted in tablets, sent as units_on_hand, whole only', (tester) async {
    final server = _Server(loose: true, quantity: 4.5);
    await open(tester, server, () async {
      await tester.tap(find.byKey(const ValueKey('edit-stock')));
      await tester.pumpAndSettle();
      expect(find.text('Tablets in stock'), findsOneWidget);
      expect(find.widgetWithText(TextField, '45'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('stock-count')), '40.5');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a whole number of tablets, 0 or more'), findsOneWidget);
      expect(server.patches, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('stock-count')), '40');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(server.patches.single, {'units_on_hand': 40});
      expect(find.text('Stock saved: 40 tablets'), findsOneWidget);
      expect(find.text('30 tablets → 40 tablets'), findsOneWidget);
    });
  });

  testWidgets('a refused count stays in the sheet with a reason', (tester) async {
    final server = _Server()
      ..failStatus = 422
      ..failWith = {'detail': {'error': 'bad_quantity'}};
    await open(tester, server, () async {
      await tester.tap(find.byKey(const ValueKey('edit-stock')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('stock-count')), '7');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('That count is not allowed.'), findsOneWidget);
      expect(find.byKey(const ValueKey('stock-count')), findsOneWidget, reason: 'the sheet stays open');
    });
  });

  test('setProductStock sends exactly one count and reads the record back', () async {
    final server = _Server(loose: true);
    await http.runWithClient(() async {
      final r = await ApiClient.instance.setProductStock(1, unitsOnHand: 20);
      expect(server.patches.single, {'units_on_hand': 20});
      expect((r.quantityOnHand, r.unitsOnHand, r.edit.from, r.edit.to, r.edit.unit), (2.0, 20, 3.0, 2.0, 'loose'));
    }, () => server.client);
  });
}
