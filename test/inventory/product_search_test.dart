import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/product_catalog.dart';
import 'package:gst_bill_app/features/inventory/models/product.dart';
import 'package:gst_bill_app/features/inventory/models/product_search.dart';
import 'package:gst_bill_app/features/inventory/presentation/inventory_screen.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';
import 'package:gst_bill_app/features/voice/models/voice.dart';
import 'package:gst_bill_app/features/voice/presentation/voice_order_review_screen.dart';

/// Search as the shopkeeper types, on the phone (DAS-94).
///
/// Search used to be a server call on submit. The shop's whole list is now
/// held once and searched on every keystroke, in Inventory, on the sale screen
/// and in a voice sale's "Add item".

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

ProductSummary _p(int id, String name, [double stock = 10]) =>
    ProductSummary(id: id, name: name, quantityOnHand: stock);

/// A shop's product list as the server sends it, in its order (by name), with
/// stock the test can change between fetches.
class _Shop {
  final stock = <String, double>{
    'Crocin Advance': 20,
    'Dolo 650': 15,
    'Para-Cet 500': 8,
    'Paracetamol 500mg': 30,
    'Spara Syrup': 5,
  };
  int listRequests = 0;
  final searches = <String>[];

  MockClient get client => MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/inventory/products') {
          final q = req.url.queryParameters['q'];
          if (q != null) searches.add(q);
          listRequests++;
          var id = 0;
          return _json([
            for (final e in stock.entries)
              {'id': ++id, 'name': e.key, 'quantity_on_hand': e.value},
          ]);
        }
        return http.Response('not found', 404);
      });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<String> _names(WidgetTester tester, Iterable<String> all) =>
    [for (final n in all) if (find.text(n).evaluate().isNotEmpty) n];

void main() {
  setUp(() => ApiClient.instance.token = 'session-1');
  tearDown(() => ApiClient.instance.token = null);

  group('normalizeProductName matches the server', () {
    // Expected values are the server's own `normalize_product_name` output,
    // run on these exact strings (2026-10-19).
    const fromServer = {
      'Paracetamol 500mg': 'paracetamol 500mg',
      '  PARA-CET  Tab. ': 'paracet tab',
      'Dolo_650': 'dolo_650',
      "Vit. B12 (10's)": 'vit b12 10s',
      'Crocin  Advance\tTab': 'crocin advance tab',
      'पैरासिटामोल ५०० टैब': 'परसटमल ५०० टब',
      'Café Crème': 'café crème',
      'A.B.C': 'abc',
      '': '',
      '...': '',
      'Ⅻ ½ tab': 'ⅻ ½ tab',
    };
    fromServer.forEach((raw, expected) {
      test('"$raw"', () => expect(normalizeProductName(raw), expected));
    });
  });

  group('ProductIndex.match', () {
    final index = ProductIndex([
      _p(1, 'Crocin Advance'),
      _p(2, 'Para-Cet 500'),
      _p(3, 'Paracetamol 500mg'),
      _p(4, 'Spara Syrup'),
    ]);

    test('every product whose name contains the text, anywhere in it, in list order', () {
      expect(index.match('para').map((p) => p.id), [2, 3, 4]);
    });

    test('case and punctuation do not matter, on either side', () {
      expect(index.match('PARA-CET 5').map((p) => p.id), [2]);
      expect(index.match('paracet 5').map((p) => p.id), [2]);
    });

    test('nothing typed, or only punctuation, is every product — as on the server', () {
      expect(index.match('').length, 4);
      expect(index.match(' . ').length, 4);
    });

    test('no match is an empty list', () => expect(index.match('xyz'), isEmpty));
  });

  group('ProductIndex.qualifier — the pack beside a name only when the shop has the name twice (ADR-020)', () {
    ProductSummary p(int id, String name, {String? pack, double? mrp}) =>
        ProductSummary(id: id, name: name, pack: pack, mrp: mrp, quantityOnHand: 1);

    test('a name the shop has once gets nothing, pack or not', () {
      final index = ProductIndex([p(1, 'Dolo 650', pack: '15 Tab', mrp: 31), p(2, 'Volini Gel', pack: '30GM')]);
      expect(index.qualifier(1), isNull);
      expect(index.qualifier(2), isNull);
      expect(index.sharesName(1), isFalse);
      expect(index.label(1, 'Dolo 650'), 'Dolo 650');
    });

    test('the same brand in two packs: each shows its pack', () {
      final index = ProductIndex([
        p(1, 'Prominent Charcoal', pack: '60GM', mrp: 140),
        p(2, 'Prominent Charcoal', pack: '100GM', mrp: 185),
      ]);
      expect(index.qualifier(1), '60GM');
      expect(index.qualifier(2), '100GM');
      expect(index.label(2, 'Prominent Charcoal'), 'Prominent Charcoal · 100GM');
    });

    test('a namesake with no pack shows its MRP instead', () {
      final index = ProductIndex([
        p(1, 'Prominent Charcoal', pack: '60GM', mrp: 140),
        p(2, 'Prominent Charcoal', mrp: 185),
      ]);
      expect(index.qualifier(1), '60GM');
      expect(index.qualifier(2), '₹185');
    });

    test('the same pack at two prices: MRP tells them apart, pack would not', () {
      final index = ProductIndex([
        p(1, 'Prominent Charcoal', pack: '60GM', mrp: 140),
        p(2, 'Prominent Charcoal', pack: '60 gm', mrp: 150.5),
      ]);
      expect(index.qualifier(1), '₹140');
      expect(index.qualifier(2), '₹150.50');
    });

    test('names match the way the server matches them: case and punctuation aside', () {
      final index = ProductIndex([p(1, 'PROMINENT CHARCOAL', pack: '60GM'), p(2, 'Prominent  Charcoal.', pack: '100GM')]);
      expect(index.sharesName(1), isTrue);
      expect(index.sharesName(2), isTrue);
    });

    test('nothing on record to tell them apart: the name stands alone, not a blank', () {
      final index = ProductIndex([p(1, 'Prominent Charcoal'), p(2, 'Prominent Charcoal')]);
      expect(index.qualifier(1), isNull);
      expect(index.sharesName(1), isTrue);
    });
  });

  group('ProductCatalog', () {
    test('a list fetched before a sign-out is not shown to the next sign-in', () async {
      final shop = _Shop();
      await http.runWithClient(() async {
        await ProductCatalog.instance.refresh();
        expect(ProductCatalog.instance.index, isNotNull);
        ApiClient.instance.token = 'session-2';
        expect(ProductCatalog.instance.index, isNull);
      }, () => shop.client);
    });

    test('callers at the same moment share one request', () async {
      final shop = _Shop();
      ApiClient.instance.token = 'session-3';
      await http.runWithClient(() async {
        await Future.wait([ProductCatalog.instance.refresh(), ProductCatalog.instance.refresh()]);
      }, () => shop.client);
      expect(shop.listRequests, 1);
    });
  });

  testWidgets('Inventory: typing "para" narrows the list on every letter, with no request per letter', (tester) async {
    final shop = _Shop();
    ApiClient.instance.token = 'inventory';
    final key = GlobalKey<InventoryScreenState>();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: InventoryScreen(key: key))));
      await key.currentState!.refresh(); // what opening the tab does
      await _settle(tester);
      expect(_names(tester, shop.stock.keys), shop.stock.keys.toList(), reason: 'nothing typed: every product');

      final field = find.byKey(const ValueKey('inventory-search'));
      final seen = <String, List<String>>{};
      for (final typed in ['p', 'pa', 'par', 'para']) {
        await tester.enterText(field, typed);
        await tester.pump();
        seen[typed] = _names(tester, shop.stock.keys);
      }
      expect(seen['para'], ['Para-Cet 500', 'Paracetamol 500mg', 'Spara Syrup']);
      expect(seen['p'], ['Para-Cet 500', 'Paracetamol 500mg', 'Spara Syrup']);
      expect(shop.listRequests, 1, reason: 'one fetch when the tab opened; typing asks nothing');
      expect(shop.searches, isEmpty, reason: 'the server is never asked to search');
    }, () => shop.client);
  });

  testWidgets('Inventory: stock shown is what the server says after the tab is opened again (a sale, a saved bill)',
      (tester) async {
    final shop = _Shop();
    ApiClient.instance.token = 'fresh';
    final key = GlobalKey<InventoryScreenState>();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: InventoryScreen(key: key))));
      await key.currentState!.refresh();
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('inventory-search')), 'dolo');
      await tester.pump();
      expect(find.text('15 in stock'), findsOneWidget);

      shop.stock['Dolo 650'] = 12; // 3 sold — or 40 more from a saved bill
      await key.currentState!.refresh();
      await _settle(tester);
      expect(find.text('12 in stock'), findsOneWidget, reason: 'the search stays, the stock is new');
      expect(find.text('15 in stock'), findsNothing);
    }, () => shop.client);
  });

  testWidgets('Sale screen: typing "para" narrows the list on every letter', (tester) async {
    final shop = _Shop();
    ApiClient.instance.token = 'sale';
    final key = GlobalKey<SalesScreenState>();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: SalesScreen(key: key)));
      await key.currentState!.refresh();
      await _settle(tester);
      final field = find.byKey(const ValueKey('sale-search'));
      await tester.enterText(field, 'pa');
      await tester.pump();
      expect(_names(tester, shop.stock.keys), ['Para-Cet 500', 'Paracetamol 500mg', 'Spara Syrup']);
      await tester.enterText(field, 'para');
      await tester.pump();
      expect(_names(tester, shop.stock.keys), ['Para-Cet 500', 'Paracetamol 500mg', 'Spara Syrup']);
      await tester.enterText(field, 'paracetam');
      await tester.pump();
      expect(_names(tester, shop.stock.keys), ['Paracetamol 500mg']);
      expect(shop.searches, isEmpty);
    }, () => shop.client);
  });

  testWidgets('Voice "Add item": typing "para" lists every match, with nothing listed before anything is typed',
      (tester) async {
    final shop = _Shop();
    ApiClient.instance.token = 'voice';
    final order = VoiceOrder.fromJson({'id': 1, 'transcript': '', 'status': 'draft', 'lines': []});
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1000));
      await tester.pumpWidget(MaterialApp(home: VoiceOrderReviewScreen(order: order)));
      await tester.tap(find.text('Add item'));
      await _settle(tester);
      expect(_names(tester, shop.stock.keys), isEmpty);

      final field = find.byKey(const ValueKey('add-item-search'));
      await tester.enterText(field, 'para');
      await tester.pump();
      expect(_names(tester, shop.stock.keys), ['Para-Cet 500', 'Paracetamol 500mg', 'Spara Syrup']);
      await tester.enterText(field, 'paracet');
      await tester.pump();
      expect(_names(tester, shop.stock.keys), ['Para-Cet 500', 'Paracetamol 500mg']);
      expect(shop.searches, isEmpty);
    }, () => shop.client);
  });

  testWidgets('a sale refused for a merged batch takes that line out of the cart and refreshes the list (DAS-93)',
      (tester) async {
    var listFetches = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/sales') return _json({'detail': 'batch 12 not found'}, 404);
      if (req.url.path == '/inventory/products') {
        listFetches++;
        return _json([]);
      }
      return http.Response('not found', 404);
    });
    ApiClient.instance.token = 'merge';
    final cart = [
      CartEntry(productBatchId: 12, productName: 'Dolo 650', qty: 1, rate: 30, gstPct: 12),
      CartEntry(productBatchId: 13, productName: 'Crocin Advance', qty: 2, rate: 20, gstPct: 12),
    ];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: cart)));
      await tester.tap(find.textContaining('Complete'));
      await _settle(tester);
      expect(cart.map((c) => c.productBatchId), [13], reason: 'only the merged line goes');
      expect(find.textContaining('Dolo 650 was merged into another'), findsOneWidget);
      expect(listFetches, 1);
    }, () => client);
  });
}
