import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

/// Sending a saved bill back to Check & save, from the ✕ on its card.
///
/// The ask: an option on a saved bill to move it back to the status it had
/// before saving, asking whether to take its stock out of inventory too. The
/// stock decision is the shopkeeper's, asked every time — never assumed.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Server {
  _Server({this.refuse});

  /// A 409 message to answer the unsave with (stock already sold).
  final String? refuse;
  var saved = true;
  final unsaves = <Map<String, dynamic>>[];

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          return _json({
            'jobs': [
              {
                'job_id': 10,
                'status': 'done',
                'source_image': '8/10.jpg',
                'created_at': '2026-10-08T10:00:00Z',
                'issue_count': 0,
                'invoice_id': saved ? 55 : null,
                'seller_name': 'RADHE PHARMA',
              },
            ],
            'next_before_id': null,
            'counts': {'root': {(saved ? 'saved' : 'check'): 1}},
          });
        }
        if (req.method == 'POST' && path == '/invoices/55/unsave') {
          unsaves.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (refuse != null) return _json({'detail': refuse}, 409);
          saved = false;
          return _json({'ok': true, 'job_id': 10});
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
  await tester.binding.setSurfaceSize(const Size(400, 900));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
  await _settle(tester);
}

final _card = find.byKey(const ValueKey('j:10'));
Finder get _cross => find.descendant(of: _card, matching: find.byIcon(Icons.close_rounded));
Finder _on(String text) => find.descendant(of: _card, matching: find.text(text));

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(_cross);
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the cross on a saved bill asks, and does nothing until answered', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      expect(_on('Saved'), findsOneWidget);
      await _openDialog(tester);

      expect(find.text('Move back to Check & save?'), findsOneWidget);
      expect(find.textContaining('stock'), findsWidgets);
      expect(server.unsaves, isEmpty);
    }, () => server.client);
  });

  testWidgets('"Keep stock" moves it back and leaves inventory alone', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await _openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('unsave-keep')));
      await _settle(tester);

      expect(server.unsaves, [
        {'remove_stock': false},
      ]);
      expect(find.textContaining('Its stock stays in inventory'), findsOneWidget);
      expect(_on('Saved'), findsNothing, reason: 'it is no longer saved');
      expect(_on('Check & save'), findsOneWidget, reason: 'it is back in Check & save');
    }, () => server.client);
  });

  testWidgets('"Remove stock" asks for the stock to be taken out too', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await _openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('unsave-remove')));
      await _settle(tester);

      expect(server.unsaves, [
        {'remove_stock': true},
      ]);
      expect(find.textContaining('taken out of inventory'), findsOneWidget);
    }, () => server.client);
  });

  testWidgets('cancelling changes nothing and asks the server nothing', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await _openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('unsave-cancel')));
      await _settle(tester);

      expect(server.unsaves, isEmpty);
      expect(_on('Saved'), findsOneWidget);
    }, () => server.client);
  });

  testWidgets('stock already sold: it says why and the bill stays saved', (tester) async {
    _ignoreOverflow();
    final server = _Server(refuse: 'some of this invoice\'s stock has already been sold');
    await http.runWithClient(() async {
      await _open(tester);
      await _openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('unsave-remove')));
      await _settle(tester);

      expect(find.textContaining("Couldn't move it back"), findsOneWidget);
      expect(find.textContaining('already been sold'), findsOneWidget);
      expect(_on('Saved'), findsOneWidget, reason: 'nothing changed');
    }, () => server.client);
  });
}
