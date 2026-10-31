import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/utils/format.dart';
import 'package:gst_bill_app/features/inventory/models/product.dart';
import 'package:gst_bill_app/features/inventory/models/product_search.dart';
import 'package:gst_bill_app/features/inventory/presentation/inventory_screen.dart';

/// Inventory's "Expiring within a month" filter: from the soonest unexpired
/// in-stock batch the list already carries, on the phone.

ProductSummary _p(int id, String name, String? expiry) =>
    ProductSummary(id: id, name: name, quantityOnHand: 10, expiryDate: expiry);

List<String> _names(List<ProductSummary> products) => [for (final p in products) p.name];

void main() {
  group('oneMonthAfter', () {
    test('the same day next month', () {
      expect(oneMonthAfter(DateTime(2026, 10, 31)), DateTime(2026, 11, 30), reason: 'November has 30 days');
      expect(oneMonthAfter(DateTime(2026, 10, 15)), DateTime(2026, 11, 15));
    });
    test('held to the last day of a short month, across a year and in a leap year', () {
      expect(oneMonthAfter(DateTime(2027, 1, 31)), DateTime(2027, 2, 28));
      expect(oneMonthAfter(DateTime(2028, 1, 31)), DateTime(2028, 2, 29));
      expect(oneMonthAfter(DateTime(2026, 12, 20)), DateTime(2027, 1, 20));
    });
  });

  group('expiringWithinAMonth', () {
    final today = DateTime(2026, 10, 31, 18, 30); // the time of day does not matter
    final products = [
      _p(1, 'Azithral 500', '2026-11-30'), // the last day in
      _p(2, 'Benadryl', '2026-12-01'), // a day too late
      _p(3, 'Crocin', '2026-10-31'), // today
      _p(4, 'Dolo 650', null), // nothing in stock, or all of it expired
      _p(5, 'Eno', '2026-11-05'),
      _p(6, 'Fexo 120', '2026-10-30'), // the server never sends an expired one; ignored if it does
      _p(7, 'Gelusil', '2026-11-05'),
    ];

    test('both ends included, soonest first, a tie in the list order', () {
      expect(_names(expiringWithinAMonth(products, today)), ['Crocin', 'Eno', 'Gelusil', 'Azithral 500']);
    });

    test('nothing expiring is an empty list, and the input is left as it was', () {
      expect(expiringWithinAMonth([products[1], products[3]], today), isEmpty);
      expect(products.first.name, 'Azithral 500');
    });
  });

  group('expiryWarning', () {
    final today = DateTime(2026, 10, 31, 23, 59);
    test('today, tomorrow, in days, with the date', () {
      expect(expiryWarning(_p(1, 'A', '2026-10-31'), today), 'Expires today · 31 Oct 2026');
      expect(expiryWarning(_p(1, 'A', '2026-11-01'), today), 'Expires tomorrow · 01 Nov 2026');
      expect(expiryWarning(_p(1, 'A', '2026-11-30'), today), 'Expires in 30 days · 30 Nov 2026');
    });
    test('nothing for stock further out, or with no date', () {
      expect(expiryWarning(_p(1, 'A', '2026-12-01'), today), isNull);
      expect(expiryWarning(_p(1, 'A', null), today), isNull);
    });
  });

  testWidgets('Inventory: the chip counts the stock expiring within a month, shows only it and works with the search',
      (tester) async {
    final today = DateTime.now();
    String inDays(int n) => isoDate(today.add(Duration(days: n)))!;
    final list = [
      {'id': 1, 'name': 'Paracetamol 500mg', 'quantity_on_hand': 20, 'expiry_date': inDays(20)},
      {'id': 2, 'name': 'Cetirizine 10mg', 'quantity_on_hand': 5, 'expiry_date': inDays(3)},
      {'id': 3, 'name': 'ORS Sachet', 'quantity_on_hand': 40, 'expiry_date': inDays(200)},
      {'id': 4, 'name': 'Para-Cet 500', 'quantity_on_hand': 0},
    ];
    final client = MockClient((req) async => http.Response(jsonEncode(list), 200,
        headers: {'content-type': 'application/json'}));
    ApiClient.instance.token = 'expiring';
    addTearDown(() => ApiClient.instance.token = null);
    final key = GlobalKey<InventoryScreenState>();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: InventoryScreen(key: key))));
      await key.currentState!.refresh();
      await tester.pump();
      final chip = find.byKey(const ValueKey('inventory-expiring'));
      expect(find.text('Expiring within a month (2)'), findsOneWidget);
      expect(find.text('ORS Sachet'), findsOneWidget, reason: 'off: every product');
      expect(find.textContaining('Expires in 3 days'), findsOneWidget, reason: 'the date shows on the row, with or without the filter');
      expect(find.textContaining('Expires in 200 days'), findsNothing);

      await tester.tap(chip);
      await tester.pump();
      expect(find.text('ORS Sachet'), findsNothing);
      expect(find.text('Para-Cet 500'), findsNothing);
      final cetirizine = tester.getTopLeft(find.text('Cetirizine 10mg')).dy;
      final paracetamol = tester.getTopLeft(find.text('Paracetamol 500mg')).dy;
      expect(cetirizine, lessThan(paracetamol), reason: 'soonest first, not by name');

      await tester.enterText(find.byKey(const ValueKey('inventory-search')), 'para');
      await tester.pump();
      expect(find.text('Expiring within a month (1)'), findsOneWidget, reason: 'the count follows the search');
      expect(find.text('Paracetamol 500mg'), findsOneWidget);
      expect(find.text('Cetirizine 10mg'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('inventory-search')), 'ors');
      await tester.pump();
      expect(find.text('Nothing that matches expires within a month'), findsOneWidget);

      await tester.tap(chip);
      await tester.pump();
      expect(find.text('ORS Sachet'), findsOneWidget, reason: 'off again: the search alone');
    }, () => client);
  });
}
