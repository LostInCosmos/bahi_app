import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/product_catalog.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';

// Fast billing: a product's batches are loaded while its name is typed and
// kept while the shop's list is unchanged, so the batch sheet opens at once;
// after an add the search is empty and ready for the next medicine. A sheet
// only ever shows the batches of the product it was opened for.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _detail(int id, String name, String batchNo) => {
      'id': id,
      'name': name,
      'total_quantity': 40,
      'batches': [
        {
          'id': id * 10,
          'batch_no': batchNo,
          'expiry_date': '2027-03-01',
          'quantity_on_hand': 40,
          'mrp': 100,
          'gst_pct': 12,
          'is_expired': false,
        },
      ],
    };

class _Server {
  /// How long each product's batches take to come back.
  final Map<int, Duration> delay;
  /// Answers a product's request with another product's batches (a server bug).
  final Map<int, int> answerAs;
  _Server({this.delay = const {}, this.answerAs = const {}});

  final detailAsks = <int>[];
  var listVersion = 1;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (path == '/inventory/products') {
          return http.Response(
              jsonEncode([
                {'id': 1, 'name': 'Paracetamol 500mg', 'quantity_on_hand': 40, 'mrp': 100},
                {'id': 2, 'name': 'Pantoprazole 40mg', 'quantity_on_hand': 40, 'mrp': 100},
              ]),
              200,
              headers: {'content-type': 'application/json', 'etag': '"v$listVersion"'});
        }
        final m = RegExp(r'^/inventory/products/(\d+)$').firstMatch(path);
        if (m != null) {
          final id = int.parse(m[1]!);
          detailAsks.add(id);
          final wait = delay[id];
          if (wait != null) await Future<void>.delayed(wait);
          final as = answerAs[id] ?? id;
          return _json(as == 1 ? _detail(1, 'Paracetamol 500mg', 'PARA-1') : _detail(2, 'Pantoprazole 40mg', 'PANTO-2'));
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

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SalesScreen())));
    await ProductCatalog.instance.refresh();
    await tester.pumpAndSettle();
  }

  Finder plusOf(String name) =>
      find.descendant(of: find.widgetWithText(Card, name), matching: find.byIcon(Icons.add_circle_outline));

  testWidgets('typing loads the top matches, so the sheet opens with its batches and asks nothing', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester);
      await tester.enterText(find.byKey(const ValueKey('sale-search')), 'para');
      await tester.pump(const Duration(milliseconds: 400)); // a pause in typing
      await tester.pumpAndSettle();
      expect(server.detailAsks, [1], reason: 'the one match is loaded in the background');

      await tester.tap(plusOf('Paracetamol 500mg'));
      await tester.pump(); // one frame: no wait for the server
      await tester.pump(const Duration(milliseconds: 300)); // the sheet slides up
      expect(find.text('Batch PARA-1  (suggested)'), findsOneWidget);
      expect(server.detailAsks, [1], reason: 'nothing more was asked');
    }, () => server.client);
  });

  testWidgets('after an add the search is empty and the keyboard is on it, ready for the next medicine', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester);
      await tester.enterText(find.byKey(const ValueKey('sale-search')), 'para');
      await tester.pumpAndSettle();
      await tester.tap(plusOf('Paracetamol 500mg'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      final search = tester.widget<TextField>(find.byKey(const ValueKey('sale-search')));
      expect(search.controller!.text, isEmpty);
      expect(search.focusNode!.hasFocus, isTrue);
      expect(find.text('Added Paracetamol 500mg'), findsOneWidget);
      expect(find.text('View cart · 1 item'), findsOneWidget);
    }, () => server.client);
  });

  testWidgets("a slow answer for one product never shows in another product's sheet", (tester) async {
    final server = _Server(delay: {1: const Duration(seconds: 2)});
    await http.runWithClient(() async {
      await start(tester);
      await tester.tap(plusOf('Paracetamol 500mg'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Paracetamol 500mg'), findsWidgets, reason: 'its name shows while its batches load');
      // Closed before its batches arrive, and the next medicine opened.
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(plusOf('Pantoprazole 40mg'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Batch PANTO-2  (suggested)'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3)); // Paracetamol's answer arrives
      await tester.pumpAndSettle();
      expect(find.text('Batch PANTO-2  (suggested)'), findsOneWidget);
      expect(find.text('Batch PARA-1  (suggested)'), findsNothing, reason: "Paracetamol's batches stay out of this sheet");
    }, () => server.client);
  });

  testWidgets("a server answer for the wrong product is refused, not shown under this one's name", (tester) async {
    final server = _Server(answerAs: {1: 2});
    await http.runWithClient(() async {
      await start(tester);
      await tester.tap(plusOf('Paracetamol 500mg'));
      await tester.pumpAndSettle();
      expect(find.text('Batch PANTO-2  (suggested)'), findsNothing);
      expect(find.text('Could not load this medicine. Close and try again.'), findsOneWidget);
    }, () => server.client);
  });

  testWidgets('batches held are dropped when the shop list changes (a sale, a saved bill)', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester);
      await tester.tap(plusOf('Paracetamol 500mg'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      expect(server.detailAsks, [1]);

      server.listVersion = 2; // stock moved on the server
      await ProductCatalog.instance.refresh();
      await tester.pumpAndSettle();
      await tester.tap(plusOf('Paracetamol 500mg'));
      await tester.pumpAndSettle();
      expect(server.detailAsks, [1, 1], reason: 'asked again: what was held may be out of date');
    }, () => server.client);
  });
}
