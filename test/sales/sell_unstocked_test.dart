import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/inventory_api.dart';
import 'package:gst_bill_app/features/inventory/data/product_catalog.dart';
import 'package:gst_bill_app/features/inventory/widgets/new_product_form.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';

/// DAS-172: an item the shop does not have yet is added from the Sell tab with
/// its name, MRP and GST at 0 stock, billed at once from its one batch, and the
/// sale goes through as an oversell so the stock stays at 0.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Server {
  final List<Map<String, dynamic>> created = [];
  final List<Map<String, dynamic>> sales = [];
  int conflictStatus = 0;

  MockClient get client => MockClient((req) async {
        if (req.url.path == '/inventory/products' && req.method == 'GET') {
          return _json([
            {'id': 1, 'name': 'Paracetamol 650', 'quantity_on_hand': 4, 'mrp': 100},
            if (created.isNotEmpty)
              {'id': 9, 'name': created.last['name'], 'quantity_on_hand': 0, 'mrp': created.last['mrp']},
          ]);
        }
        if (req.url.path == '/inventory/products' && req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          if (conflictStatus != 0) {
            return _json({'detail': "'ZINCOVIT DROPS' already exists — pick it instead of adding a new one"}, conflictStatus);
          }
          created.add(body);
          return _json({
            'id': 9,
            'name': body['name'],
            'hsn_code': null,
            'pack': null,
            'quantity_on_hand': body['quantity'],
            'batch_id': 42,
          });
        }
        if (req.url.path == '/inventory/products/9') {
          return _json({
            'id': 9,
            'name': created.last['name'],
            'total_quantity': 0,
            'batches': [
              {
                'id': 42,
                'batch_no': 'MANUAL-1a2b3c4d',
                'expiry_date': null,
                'quantity_on_hand': 0,
                'mrp': created.last['mrp'],
                'gst_pct': created.last['gst_pct'],
                'is_expired': false,
                'units_per_pack': null,
                'sold_loose': false,
                'unit_kind': null,
                'units_on_hand': null,
                'unit_mrp': null,
              },
            ],
          });
        }
        if (req.url.path == '/sales' && req.method == 'POST') {
          sales.add(jsonDecode(req.body) as Map<String, dynamic>);
          return _json({
            'sale_id': 5,
            'sale_no': '2026-27/0007',
            'grand_total': 90.0,
            'oversold': [
              {'product_batch_id': 42, 'product_name': 'ZINCOVIT DROPS', 'requested': 1, 'available': 0, 'short_by': 1},
            ],
          });
        }
        return http.Response('no', 404);
      });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
  });
  tearDown(() => ApiClient.instance.token = null);

  Future<void> open(WidgetTester tester, _Server server, Future<void> Function() body) =>
      http.runWithClient(() async {
        tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SalesScreen())));
        await ProductCatalog.instance.refresh();
        await tester.pumpAndSettle();
        await body();
      }, () => server.client);

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('sale-search')), text);
    await tester.pumpAndSettle();
  }

  testWidgets('the add-new-product button appears only once something is typed', (tester) async {
    await open(tester, _Server(), () async {
      expect(find.byKey(const ValueKey('sale-add-new-product')), findsNothing);
      await search(tester, 'zinc');
      expect(find.text('No products found'), findsOneWidget);
      expect(find.text("Can't find it? Add as new product"), findsOneWidget);
      await search(tester, 'para');
      expect(find.text('Paracetamol 650'), findsOneWidget);
      expect(find.text("Can't find it? Add as new product"), findsOneWidget, reason: 'offered under the matches too');
    });
  });

  testWidgets('an unstocked item is created at 0 stock with source=sale, then billed from its batch as an oversell',
      (tester) async {
    final server = _Server();
    await open(tester, server, () async {
      await search(tester, 'zincovit');
      await tester.tap(find.byKey(const ValueKey('sale-add-new-product')));
      await tester.pumpAndSettle();
      expect(find.text('Add new product'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('new-product-name'))).controller!.text, 'zincovit',
          reason: 'the search text is the name to start from');
      expect(find.text('Quantity in stock'), findsNothing, reason: 'the item starts at 0 stock');

      await tester.enterText(find.byKey(const ValueKey('new-product-name')), 'ZINCOVIT DROPS');
      await tester.enterText(find.byKey(const ValueKey('new-product-mrp')), '90');
      await tester.enterText(find.byKey(const ValueKey('new-product-gst')), '12');
      await tester.tap(find.text('Create & continue'));
      await tester.pumpAndSettle();

      expect(server.created.single, {'name': 'ZINCOVIT DROPS', 'mrp': 90, 'quantity': 0, 'unit': 'bottle', 'gst_pct': 12, 'source': 'sale'});
      // Its batch picker opened at once, at the MRP, with none in stock.
      expect(find.text('ZINCOVIT DROPS'), findsWidgets);
      expect(find.text('Available: 0'), findsOneWidget);
      expect(find.widgetWithText(TextField, '90.00'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('View cart'));
      await tester.pumpAndSettle();
      expect(find.byType(SaleReviewScreen), findsOneWidget);
      expect(find.textContaining('ZINCOVIT DROPS × 1'), findsOneWidget); // "× 1 pc" once DAS-170 is in
      expect(find.textContaining('None in inventory'), findsOneWidget, reason: 'the DAS-111 note, never on the bill');

      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
      final line = (server.sales.single['line_items'] as List).single as Map<String, dynamic>;
      expect(line['product_batch_id'], 42);
      expect(line['qty'], 1);
      expect(line['rate'], 90);
      expect(server.sales.single['allow_oversell'], isTrue);
    });
  });

  testWidgets('a name the shop already has is refused by the server and the form says which', (tester) async {
    final server = _Server()..conflictStatus = 409;
    await open(tester, server, () async {
      await search(tester, 'zincovit drops');
      await tester.tap(find.byKey(const ValueKey('sale-add-new-product')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('new-product-mrp')), '90');
      await tester.enterText(find.byKey(const ValueKey('new-product-gst')), '12');
      await tester.tap(find.text('Create & continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining("'ZINCOVIT DROPS' already exists"), findsOneWidget);
      expect(find.text('Add new product'), findsOneWidget, reason: 'the form stays open to fix the name');
    });
  });

  test('the unit is guessed from the name, and left for the shopkeeper when the name says nothing', () {
    expect(guessUnit('ZINCOVIT DROPS'), 'bottle');
    expect(guessUnit('Dolo 650 Tab'), 'tablet');
    expect(guessUnit('CALTROL PLUS CAP'), 'capsule');
    expect(guessUnit('BETADINE OINTMENT 20G'), 'tube');
    expect(guessUnit('BENADRYL COUGH SYRUP 100ML'), 'bottle');
    expect(guessUnit('ORS ORANGE 21G SACHET'), 'sachet');
    expect(guessUnit('AMOXY 500 INJ'), 'vial');
    expect(guessUnit('CALCITAS D3 SOFTGEL'), 'capsule');
    expect(guessUnit('NERVITOP'), isNull);
    expect(guessUnit(''), isNull);
  });

  testWidgets('a name that says nothing leaves the unit unpicked, and Create asks for it', (tester) async {
    final server = _Server();
    await open(tester, server, () async {
      await search(tester, 'nervitop');
      await tester.tap(find.byKey(const ValueKey('sale-add-new-product')));
      await tester.pumpAndSettle();
      expect(find.text('Pick one'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('new-product-mrp')), '265');
      await tester.tap(find.text('Create & continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter the GST rate on the pack: 0, 5, 12 or 18.'), findsOneWidget, reason: 'GST is not prefilled');
      await tester.enterText(find.byKey(const ValueKey('new-product-gst')), '5');
      await tester.tap(find.text('Create & continue'));
      await tester.pumpAndSettle();
      expect(find.text('Pick a unit: how this item is counted.'), findsOneWidget);
      expect(server.created, isEmpty);
      // Typing a telling name fills it in.
      await tester.enterText(find.byKey(const ValueKey('new-product-name')), 'NERVITOP GEL');
      await tester.pumpAndSettle();
      expect(find.text('tube'), findsOneWidget);
    });
  });

  test('createProduct sends source only when given and reads batch_id', () async {
    final server = _Server();
    await http.runWithClient(() async {
      final created = await ApiClient.instance.createProduct(name: 'X', mrp: 10, quantity: 0, unit: 'tablet', source: 'sale');
      expect(created.batchId, 42);
      expect(created.product.quantityOnHand, 0);
      expect(server.created.last['source'], 'sale');
      await ApiClient.instance.createProduct(name: 'Y', mrp: 10, quantity: 2, unit: 'strip');
      expect(server.created.last.containsKey('source'), isFalse, reason: 'the voice add sends what it always did');
    }, () => server.client);
  });
}
