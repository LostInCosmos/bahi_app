import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/utils/format.dart';
import 'package:gst_bill_app/features/dashboard/presentation/dashboard_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_tabs.dart';
import 'package:gst_bill_app/features/inventory/models/product_search.dart';
import 'package:gst_bill_app/features/inventory/presentation/inventory_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_history_screen.dart';

/// DAS-186: the Home tab, ported from the web's Dashboard.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Host implements HomeTabHost {
  final selected = <String>[];
  final payloads = <Object?>[];
  @override
  void select(String id, {Object? payload}) {
    selected.add(id);
    payloads.add(payload);
  }
}

String _day(int offset) => isoDate(DateTime.now().add(Duration(days: offset)))!;

MockClient _server({bool empty = false, bool fail = false}) => MockClient((req) async {
      final path = req.url.path;
      if (fail && path != '/account') return http.Response('{"detail":"down"}', 503);
      if (path == '/account') return _json({'tenant_name': 'Om Medicals', 'email': 'om@example.com', 'business_type': 'pharmacy'});
      if (path == '/sales') {
        return _json(empty
            ? []
            : [
                {'id': 2, 'sale_no': 'S-2', 'sale_date': _day(0), 'buyer_name': 'Ramesh', 'grand_total': 300},
                {'id': 1, 'sale_no': 'S-1', 'sale_date': _day(0), 'grand_total': 100},
              ]);
      }
      if (path == '/invoices') return _json([]);
      if (path == '/inventory/products') {
        return _json(empty
            ? []
            : [
                {'id': 1, 'name': 'Dolo 650', 'quantity_on_hand': 2, 'net_rate': 20},
                {'id': 2, 'name': 'Zyrtec', 'quantity_on_hand': 0},
                {'id': 3, 'name': 'Crocin', 'quantity_on_hand': 10, 'expiry_date': _day(5), 'net_rate': 10},
              ]);
      }
      return http.Response('not found', 404);
    });

Future<_Host> _open(WidgetTester tester) async {
  final host = _Host();
  final key = GlobalKey<DashboardScreenState>();
  await tester.binding.setSurfaceSize(const Size(400, 2400));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: DashboardScreen(key: key, host: host))));
  await key.currentState!.refresh();
  await tester.pump();
  return host;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = 'dashboard';
  });
  tearDown(() => ApiClient.instance.token = null);

  testWidgets("today's figures, the shelf and recent bills", (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text('Om Medicals'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-today-total')), findsOneWidget);
      expect(find.text('₹400'), findsWidgets, reason: "today's 100 + 300");
      expect(find.text('₹200'), findsOneWidget, reason: 'average bill');
      expect(find.text('Recent bills'), findsNothing, reason: 'View sales is the way to them (as on the web)');
      expect(find.text('Only 2 packs left'), findsOneWidget);
      expect(find.text('Out of stock'), findsWidgets);
      expect(find.text('expires in 5 days · 10 packs'), findsOneWidget);
      expect(find.text('Running low · 1'), findsOneWidget);
      expect(find.text('Out of stock · 1'), findsOneWidget);
    }, () => _server());
  });

  testWidgets('a tile and the links open Inventory with their filter on', (tester) async {
    await http.runWithClient(() async {
      final host = await _open(tester);
      await tester.tap(find.byKey(const ValueKey('home-tile-low')));
      await tester.tap(find.byKey(const ValueKey('home-link-out')));
      await tester.tap(find.byKey(const ValueKey('home-tile-expiring')));
      await tester.tap(find.byKey(const ValueKey('home-start-billing')));
      expect(host.selected, ['inventory', 'inventory', 'inventory', 'sell']);
      expect((host.payloads[0] as InventoryFilter).stock, StockFilter.low);
      expect((host.payloads[1] as InventoryFilter).stock, StockFilter.out);
      expect((host.payloads[2] as InventoryFilter).expiring, isTrue);
    }, () => _server());
  });

  testWidgets('View sales opens the sales history', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('home-view-sales')));
      await tester.pumpAndSettle();
      expect(find.byType(SalesHistoryPage), findsOneWidget);
    }, () => _server());
  });

  testWidgets('a new shop: zeros and the empty texts', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text('₹0'), findsWidgets);
      expect(find.text('Nothing expired or expiring in 90 days, and nothing running low.'), findsOneWidget);
      expect(find.text('Add a purchase bill to see it'), findsOneWidget);
    }, () => _server(empty: true));
  });

  testWidgets('a failed load says so and offers Try again', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.textContaining('Could not load the dashboard'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    }, () => _server(fail: true));
  });

  testWidgets('Inventory: Running low and Out of stock chips, and a hand-off turns one on', (tester) async {
    final key = GlobalKey<InventoryScreenState>();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: InventoryScreen(key: key))));
      await key.currentState!.refresh();
      await tester.pump();
      expect(find.text('Running low (1)'), findsOneWidget);
      expect(find.text('Out of stock (1)'), findsOneWidget);
      expect(find.text('Crocin'), findsOneWidget);

      key.currentState!.handoff(const InventoryFilter(stock: StockFilter.low));
      await tester.pump();
      expect(find.text('Dolo 650'), findsOneWidget);
      expect(find.text('Crocin'), findsNothing);
      expect(find.textContaining('RUNNING LOW'), findsOneWidget);

      key.currentState!.handoff(const InventoryFilter(stock: StockFilter.out));
      await tester.pump();
      expect(find.text('Zyrtec'), findsOneWidget);
      expect(find.text('Dolo 650'), findsNothing);
    }, () => _server());
  });
}
