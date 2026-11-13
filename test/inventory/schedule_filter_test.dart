import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/presentation/inventory_screen.dart';
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

/// DAS-183: Inventory filters by drug schedule (H, H1, X), a chip only for a
/// schedule the shop has; the shop tags a medicine itself on its product page.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  setUp(() => ApiClient.instance.token = 'schedule');
  tearDown(() => ApiClient.instance.token = null);

  Future<GlobalKey<InventoryScreenState>> openInventory(WidgetTester tester, List<Map<String, Object?>> list) async {
    final key = GlobalKey<InventoryScreenState>();
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: InventoryScreen(key: key))));
    await key.currentState!.refresh();
    await tester.pump();
    return key;
  }

  testWidgets('a chip for each schedule the shop has, with its count; picking one shows only those', (tester) async {
    final list = [
      {'id': 1, 'name': 'Montair LC', 'quantity_on_hand': 20, 'schedule': 'H1'},
      {'id': 2, 'name': 'Zyrtec', 'quantity_on_hand': 5, 'schedule': 'H1'},
      {'id': 3, 'name': 'Azithral 500', 'quantity_on_hand': 9, 'schedule': 'H'},
      {'id': 4, 'name': 'ORS Sachet', 'quantity_on_hand': 40},
    ];
    await http.runWithClient(() async {
      await openInventory(tester, list);
      expect(find.text('Schedule H1 (2)'), findsOneWidget);
      expect(find.text('Schedule H (1)'), findsOneWidget);
      expect(find.textContaining('Schedule X'), findsNothing, reason: 'the shop has none');
      expect(find.text('ORS Sachet'), findsOneWidget, reason: 'off: every product');

      await tester.tap(find.byKey(const ValueKey('inventory-schedule-H1')));
      await tester.pump();
      expect(find.text('Montair LC'), findsOneWidget);
      expect(find.text('Zyrtec'), findsOneWidget);
      expect(find.text('Azithral 500'), findsNothing);
      expect(find.text('ORS Sachet'), findsNothing);
      expect(find.textContaining('SCHEDULE H1'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('inventory-search')), 'zyr');
      await tester.pump();
      expect(find.text('Zyrtec'), findsOneWidget, reason: 'it works with the search');
      expect(find.text('Montair LC'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('inventory-search')), '');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('inventory-schedule-H1')));
      await tester.pump();
      expect(find.text('ORS Sachet'), findsOneWidget, reason: 'tapped again: off');
    }, () => MockClient((req) async => _json(list)));
  });

  testWidgets('no chips at all when nothing is tagged (or the server sends no schedule)', (tester) async {
    final list = [
      {'id': 1, 'name': 'Dolo 650', 'quantity_on_hand': 20},
      {'id': 2, 'name': 'ORS Sachet', 'quantity_on_hand': 40, 'schedule': null},
    ];
    await http.runWithClient(() async {
      await openInventory(tester, list);
      expect(find.textContaining('Schedule'), findsNothing);
      expect(find.byKey(const ValueKey('inventory-expiring')), findsOneWidget);
    }, () => MockClient((req) async => _json(list)));
  });

  group('the product page', () {
    final patches = <Map<String, dynamic>>[];
    var refuse = false;

    Map<String, Object?> detail(String? schedule) => {
          'id': 7, 'name': 'Montair LC', 'total_quantity': 20, 'batches': [], 'schedule': schedule,
        };

    MockClient server(String? schedule) => MockClient((req) async {
          if (req.method == 'PATCH' && req.url.path == '/inventory/products/7') {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            patches.add(body);
            if (refuse) return _json({'detail': 'schedule must be H or H1'}, 422);
            final s = body['schedule'] as String;
            return _json({'id': 7, 'schedule': s.isEmpty ? null : s});
          }
          if (req.url.path == '/inventory/products/7') return _json(detail(schedule));
          if (req.url.path == '/inventory/products') return _json([]);
          return http.Response('not found', 404);
        });

    setUp(() {
      patches.clear();
      refuse = false;
    });

    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(const MaterialApp(home: ProductDetailScreen(productId: 7)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    String selected(WidgetTester tester) =>
        tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('product-schedule'))).selected.single;

    testWidgets('shows the schedule, and one tap saves another', (tester) async {
      await http.runWithClient(() async {
        await open(tester);
        expect(selected(tester), 'H1');
        await tester.tap(find.text('X'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(patches.single, {'schedule': 'X'});
        expect(selected(tester), 'X');
        expect(find.text('Marked Schedule X.'), findsOneWidget);
      }, () => server('H1'));
    });

    testWidgets('None clears it with an empty schedule', (tester) async {
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(find.text('None'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(patches.single, {'schedule': ''});
        expect(selected(tester), '');
        expect(find.text('Schedule cleared.'), findsOneWidget);
      }, () => server('H1'));
    });

    testWidgets('a refusal puts the old schedule back and says why', (tester) async {
      refuse = true;
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(find.text('X'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(selected(tester), 'H1');
        expect(find.textContaining("Couldn't change the schedule"), findsOneWidget);
      }, () => server('H1'));
    });
  });
}
