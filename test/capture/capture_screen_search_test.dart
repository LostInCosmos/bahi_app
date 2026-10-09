import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

/// The search box on the real Capture screen: shop names on the cards, and
/// typing narrows them a letter at a time without asking the server anything.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

const _bills = [
  (1, 'RADHE PHARMA', 'A100'),
  (2, 'RAJ MEDICOS', 'B200'),
  (3, 'PRIYA MEDICOS', 'C300'),
  (4, 'KAPOOR TRADERS', 'R-77'),
  (5, 'SHARMA AGENCY', 'D400'),
];

class _Server {
  final lists = <String>[];

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          lists.add(req.url.query);
          return _json({
            'jobs': [
              for (final (id, shop, no) in _bills.reversed)
                {
                  'job_id': id,
                  'status': 'done',
                  'source_image': '8/$id.jpg',
                  'created_at': '2026-10-08T10:00:00Z',
                  'issue_count': 0,
                  'seller_name': shop,
                  'invoice_no': no,
                },
            ],
            'next_before_id': null,
            'counts': {'root': {'check': 5}},
          });
        }
        return http.Response('not found', 404);
      });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _ignoreOverflow() {
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

Future<void> _open(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
  await _settle(tester);
}

Finder _card(int id) => find.byKey(ValueKey('j:$id'));

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('bill-search')), text);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('every card names its shop', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      for (final (_, shop, _) in _bills) {
        expect(find.text(shop), findsOneWidget, reason: shop);
      }
    }, () => server.client);
  });

  testWidgets('"r" shows the shops starting with r and an invoice number containing it', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await _type(tester, 'r');

      expect(_card(1), findsOneWidget);          // RADHE
      expect(_card(2), findsOneWidget);          // RAJ
      expect(_card(4), findsOneWidget);          // invoice R-77
      expect(_card(3), findsNothing);            // PRIYA has an r, but does not start with one
      expect(_card(5), findsNothing);            // nor SHARMA
    }, () => server.client);
  });

  testWidgets('"ra" narrows what "r" showed, and nothing is fetched while typing', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      final before = server.lists.length;

      await _type(tester, 'r');
      await _type(tester, 'ra');
      expect(_card(1), findsOneWidget);
      expect(_card(2), findsOneWidget);
      expect(_card(4), findsNothing, reason: 'R-77 held "r" but not "ra"');

      await _type(tester, 'rad');
      expect(_card(1), findsOneWidget);
      expect(_card(2), findsNothing);

      await _settle(tester);
      expect(server.lists.length, before, reason: 'search is on the phone — no request per keystroke');
    }, () => server.client);
  });

  testWidgets('an invoice number finds its bill, and clearing the search brings everything back', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await _type(tester, '300');
      expect(_card(3), findsOneWidget);
      expect(_card(1), findsNothing);

      await tester.tap(find.byKey(const ValueKey('bill-search-clear')));
      await tester.pump();
      for (final (id, _, _) in _bills) {
        expect(_card(id), findsOneWidget, reason: 'bill $id');
      }
    }, () => server.client);
  });

  testWidgets('a search nothing matches says so', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await _type(tester, 'zzz');
      await _settle(tester);
      expect(find.text('No bill matches that search'), findsOneWidget);
    }, () => server.client);
  });
}
