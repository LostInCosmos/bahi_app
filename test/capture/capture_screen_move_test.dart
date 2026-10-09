import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

/// Moving bills on the real Capture screen.
///
/// Reported: moving a few hundred bills took minutes, because each was its
/// own request and the list changed only after the last one. The bills must
/// leave this view the moment Move is chosen, with the server catching up
/// behind them — so the server here answers only when the test says so.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _upload(int id) => {
      'job_id': id,
      'status': 'done',
      'source_image': '8/$id.jpg',
      'created_at': '2026-10-08T10:00:00Z',
      'issue_count': 0,
    };

final _pickerRow = find.descendant(of: find.byType(ListTile), matching: find.text('Testing 2'));
const _cards = ValueKey('selection-mark');   // one per bill drawn, while choosing

class _Server {
  _Server(this.bills);

  final int bills;
  final requests = <Map<String, dynamic>>[];
  Completer<http.Response>? hold;
  http.Response Function(Map<String, dynamic> body)? answer;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') {
          return _json([
            {'id': 7, 'parent_id': null, 'name': 'Testing 2', 'bill_count': 0},
          ]);
        }
        if (req.method == 'GET' && path == '/invoices/extract') {
          return _json({
            'jobs': [for (var id = bills; id >= 1; id--) _upload(id)],
            'next_before_id': null,
          });
        }
        if (req.method == 'POST' && path == '/invoices/bulk-move') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          requests.add(body);
          if (hold != null) return hold!.future;
          return answer!(body);
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

/// Select every bill, choose Move, pick "Testing 2".
Future<void> _moveAllToTesting2(WidgetTester tester) async {
  await tester.tap(find.text('Select'));
  await _settle(tester);
  await tester.tap(find.text('Select all'));
  await _settle(tester);
  await tester.tap(find.text('Move'));
  await _settle(tester);
  await tester.tap(_pickerRow);
  await tester.pump();   // NOT settled: the server has not answered
}

Future<void> _open(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the bills leave the list at once, before the server has answered', (tester) async {
    _ignoreOverflow();
    final server = _Server(6)..hold = Completer<http.Response>();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('Select'));
      await _settle(tester);
      expect(find.byKey(_cards), findsNWidgets(6), reason: 'the fixture must show six bills to move');
      await tester.tap(find.text('Select all'));
      await _settle(tester);
      await tester.tap(find.text('Move'));
      await _settle(tester);
      await tester.tap(_pickerRow);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The server is still holding its answer…
      expect(server.requests, hasLength(1));
      expect(server.requests.single['job_ids'], unorderedEquals([1, 2, 3, 4, 5, 6]));
      expect(server.requests.single['folder_id'], 7);
      // …and the bills are already gone from home.
      expect(find.byKey(_cards), findsNothing);
      // The shopkeeper can see it is not finished.
      expect(find.byKey(const ValueKey('move-progress')), findsOneWidget);
      expect(find.textContaining('Moving 6 to Testing 2'), findsOneWidget);

      server.hold!.complete(_json({
        'moved_jobs': [1, 2, 3, 4, 5, 6], 'moved_invoices': [], 'skipped': [],
      }));
      await _settle(tester);

      expect(find.byKey(const ValueKey('move-progress')), findsNothing);
      expect(find.text('Moved 6 bills to Testing 2.'), findsOneWidget);
      expect(find.byKey(_cards), findsNothing);
    }, () => server.client);
  });

  testWidgets('bills the server refused come back', (tester) async {
    _ignoreOverflow();
    final server = _Server(6)
      ..answer = (body) => _json({
            'moved_jobs': [1, 2, 3], 'moved_invoices': [],
            'skipped': [for (final id in [4, 5, 6]) {'job_id': id, 'reason': 'saved'}],
          });
    await http.runWithClient(() async {
      await _open(tester);
      await _moveAllToTesting2(tester);
      await _settle(tester);

      expect(find.byKey(_cards), findsNWidgets(3), reason: 'the three it refused should be back at home');
      expect(find.textContaining("3 couldn't be moved and went back"), findsOneWidget);
    }, () => server.client);
  });

  testWidgets('a failed request puts everything back and says why', (tester) async {
    _ignoreOverflow();
    final server = _Server(6)..answer = (_) => http.Response('{"detail":"boom"}', 500);
    await http.runWithClient(() async {
      await _open(tester);
      await _moveAllToTesting2(tester);
      await _settle(tester);

      expect(find.byKey(_cards), findsNWidgets(6));
      expect(find.byKey(const ValueKey('move-progress')), findsNothing);
      expect(find.textContaining("6 couldn't be moved and went back"), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    }, () => server.client);
  });
}
