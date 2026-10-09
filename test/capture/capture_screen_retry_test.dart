import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

/// Trying again on a bill that failed.
///
/// Reported: "after three bills at once each failed with timeout, and now no
/// retry buttons". A bill that failed on the SHOP'S list (not held by this
/// phone) said "that bill has not finished being read yet" when tapped — not
/// true, and no way to try again — and a phone's own bill whose upload failed
/// had no ↻ button because the button needed an uploaded photo.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

BatchItem _item(BatchItemStatus status, {bool uploaded = true}) {
  final item = BatchItem(label: 'Bill', pages: [])..status = status;
  if (uploaded) item.sourceImages = ['8/1.jpg'];
  return item;
}

class _Server {
  final requests = <String>[];

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        requests.add('${req.method} $path');
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          return _json({
            'jobs': [
              {
                'job_id': 7,
                'status': 'failed',
                'source_image': '8/7.jpg',
                'created_at': '2026-10-08T10:00:00Z',
                'issue_count': 0,
              },
            ],
            'next_before_id': null,
            'counts': {'root': {'failed': 1}},
          });
        }
        if (req.method == 'GET' && path == '/invoices/extract/7') {
          return _json({
            'job_id': 7,
            'status': 'failed',
            'error': {'kind': 'attempts_exhausted', 'message': 'Qwen timed out reading this bill'},
          });
        }
        if (req.method == 'POST' && path == '/invoices/extract/7/retry') return _json({'job_id': 7});
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          // The real server holds this request open until something changes.
          // Answering at once made the screen's watch loop spin without a
          // pause, which hangs the test rather than testing anything.
          await Future<void>.delayed(const Duration(seconds: 25));
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('when a card offers its ↻ button', () {
    test('a failed bill always does, even if the upload itself is what failed', () {
      expect(_item(BatchItemStatus.failed, uploaded: false).canReprocess(choosing: false), isTrue);
      expect(_item(BatchItemStatus.failed).canReprocess(choosing: false), isTrue);
    });

    test('an uploaded bill does, whatever it has become', () {
      for (final s in [BatchItemStatus.pendingConfirm, BatchItemStatus.needsReview, BatchItemStatus.ready]) {
        expect(_item(s).canReprocess(choosing: false), isTrue, reason: '$s');
      }
    });

    test('never while it is being uploaded or read, nor while choosing', () {
      expect(_item(BatchItemStatus.preparing).canReprocess(choosing: false), isFalse);
      expect(_item(BatchItemStatus.processing).canReprocess(choosing: false), isFalse);
      expect(_item(BatchItemStatus.failed).canReprocess(choosing: true), isFalse);
    });

    test('a photo still being cropped has nothing to try again', () {
      expect(_item(BatchItemStatus.needsCrop, uploaded: false).canReprocess(choosing: false), isFalse);
    });
  });

  testWidgets("tapping a failed bill from the shop's list says why and offers Retry", (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);

      await tester.tap(find.byType(InkWell).last);
      await _settle(tester);

      expect(find.text('Qwen timed out reading this bill'), findsOneWidget);
      expect(find.textContaining('not finished being read'), findsNothing,
          reason: 'it finished — by failing');
      expect(server.requests, isNot(contains('POST /invoices/extract/7/retry')), reason: 'not until asked');

      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await _settle(tester);

      expect(server.requests, contains('POST /invoices/extract/7/retry'));

      // The status loop is now watching it; end the screen and let it wind down.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);
  });

  testWidgets('Close leaves it alone', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);

      await tester.tap(find.byType(InkWell).last);
      await _settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await _settle(tester);

      expect(server.requests.where((r) => r.contains('/retry')), isEmpty);
    }, () => server.client);
  });
}
