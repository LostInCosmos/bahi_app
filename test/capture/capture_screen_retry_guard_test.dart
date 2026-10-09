import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

/// Tapping retry on a Needs-review bill.
///
/// Reported: "it retried many". One tap retries exactly one bill — but the retried
/// bill leaves the box at once and the list closes up, so the NEXT bill is under
/// the same spot, and a second tap retries that one. And what the shopkeeper asked
/// for: when it is tapped, the bill moves to its next status immediately and
/// leaves the box it was in.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

class _Server {
  final retries = <int>[];
  final retried = <int>{};
  Completer<void>? retryGate;

  Map<String, dynamic> _row(int id) => {
        'job_id': id,
        'status': retried.contains(id) ? 'queued' : 'done',
        'source_image': '8/$id.jpg',
        'created_at': '2026-10-08T10:00:00Z',
        'issue_count': 2,
        'seller_name': 'SHOP $id',
      };

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          final review = [for (final id in [3, 2, 1]) if (!retried.contains(id)) _row(id)];
          final asked = req.url.queryParameters['category'];
          return _json({
            'jobs': asked == 'review' ? review : [for (final id in [3, 2, 1]) _row(id)],
            'next_before_id': null,
            'counts': {
              'root': {'review': review.length, if (retried.isNotEmpty) 'working': retried.length},
            },
          });
        }
        final retry = RegExp(r'^/invoices/extract/(\d+)/retry$').firstMatch(path);
        if (req.method == 'POST' && retry != null) {
          final id = int.parse(retry.group(1)!);
          retries.add(id);
          if (retryGate != null) await retryGate!.future;
          retried.add(id);
          return _json({'job_id': id});
        }
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          await Future<void>.delayed(const Duration(seconds: 25));   // held, as the real one is
          return _json({'jobs': [], 'changed': false});
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
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
  await _settle(tester);
}

Finder _retryOn(int id) =>
    find.descendant(of: find.byKey(ValueKey('j:$id')), matching: find.byIcon(Icons.refresh_rounded));

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 40));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a second tap straight after a retry does not retry another bill', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);

      await tester.tap(_retryOn(3));
      await tester.pump();
      await tester.tap(_retryOn(2));            // the next bill, a moment later
      await _settle(tester);

      expect(server.retries, [3], reason: 'only the one that was meant');
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('a second a moment later is a deliberate tap, and goes through', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);

      await tester.tap(_retryOn(3));
      await _settle(tester);
      await _settle(tester);                    // well past the lock
      await tester.tap(_retryOn(2));
      await _settle(tester);

      expect(server.retries, [3, 2]);
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('tapping retry moves the bill on at once and takes it out of the box it was in', (tester) async {
    _ignoreOverflow();
    final server = _Server()..retryGate = Completer<void>();     // the server has not answered yet
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.textContaining('Needs review 3'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('j:3')), findsOneWidget, reason: 'to start with, it is in the box');

      await tester.tap(_retryOn(3));
      await tester.pump();
      await tester.pump();                      // nothing has come back from the server

      expect(find.byKey(const ValueKey('j:3')), findsNothing, reason: 'gone from the box at once');
      expect(find.textContaining('Needs review 2'), findsOneWidget, reason: 'the box counts one fewer');
      expect(find.textContaining('Working 1'), findsOneWidget, reason: 'and Working one more');
      expect(find.byKey(const ValueKey('j:2')), findsOneWidget, reason: 'the rest stay');

      server.retryGate!.complete();
      await _settle(tester);
      expect(find.byKey(const ValueKey('j:3')), findsNothing, reason: 'and it stays gone when the server agrees');
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('a double tap in the same spot of a filtered list retries one bill, not two', (tester) async {
    _ignoreOverflow();
    final server = _Server()..retryGate = Completer<void>();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.textContaining('Needs review 3'));
      await _settle(tester);

      final spot = tester.getCenter(_retryOn(3));
      await tester.tapAt(spot);
      await tester.pump();
      await tester.pump();                      // the list has closed up: bill 2 is under the finger now
      await tester.tapAt(spot);
      await _settle(tester);

      expect(server.retries, [3], reason: 'the second tap must not reach bill 2');
      server.retryGate!.complete();
      await _finish(tester);
    }, () => server.client);
  });
}
