import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

/// A bill the server retries and then gives up on.
///
/// The watch loop saw "retrying", noted when the server would try again, then
/// saw "failed" — and kept the retry time. A bill carrying one is counted
/// under Working whatever its status says, so the failed bill stayed in
/// Working, and Working cards wear no ✕.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

MockClient _server() {
  var statusAnswers = 0;
  return MockClient((req) async {
    final path = req.url.path;
    if (req.method == 'GET' && path == '/folders') return _json([]);
    if (req.method == 'GET' && path == '/invoices/extract') {
      return _json({
        'jobs': [
          {'job_id': 7, 'status': 'failed', 'source_image': '8/7.jpg', 'created_at': '2026-10-08T10:00:00Z'},
        ],
        'next_before_id': null,
        'counts': {
          'root': {'failed': 1},
        },
      });
    }
    if (req.method == 'POST' && path == '/invoices/extract/7/retry') return _json({'job_id': 7});
    if (req.method == 'POST' && path == '/invoices/extract/status') {
      statusAnswers++;
      if (statusAnswers == 1) {
        // Due already, so the loop asks again straight away.
        final due = DateTime.now().toUtc().subtract(const Duration(minutes: 3)).toIso8601String();
        return _json({
          'jobs': [
            {'job_id': 7, 'status': 'retrying', 'attempt': 2, 'max_attempts': 3, 'retry_at': due},
          ],
          'changed': true,
        });
      }
      if (statusAnswers == 2) {
        return _json({
          'jobs': [
            {'job_id': 7, 'status': 'failed', 'attempt': 3, 'max_attempts': 3},
          ],
          'changed': true,
        });
      }
      await Future<void>.delayed(const Duration(seconds: 25));
      return _json({'jobs': [], 'changed': false});
    }
    if (req.method == 'GET' && path == '/invoices/extract/7') {
      return _json({
        'job_id': 7,
        'status': 'failed',
        'error': {'kind': 'attempts_exhausted', 'message': 'gave up after three tries'},
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a bill that fails after a server retry is failed, with its ✕', (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    final client = _server();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('j:7')), matching: find.byIcon(Icons.refresh_rounded)));
      await _settle(tester);
      await _settle(tester);

      final card = tester.widget<BatchItemCard>(find.byType(BatchItemCard));
      expect(card.item.status, BatchItemStatus.failed);
      expect(card.item.errorMessage, 'gave up after three tries');
      expect(card.item.isRetrying, isFalse, reason: 'the retry it was waiting on is over');
      expect(card.onDelete, isNotNull, reason: 'a failed bill can be removed');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => client);
  });
}
