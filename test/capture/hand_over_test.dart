import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

/// One card per bill, from the server (DAS-62).
///
/// Reported: Needs review listed 19 with Check & save ticked and 17 alone.
/// The phone kept a card for every bill it had uploaded or retried, with its
/// own idea of the status — 25 of them for retry copies discarded long before
/// still said "needs review". The phone now keeps a card only while the
/// server cannot show the bill.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

/// A token for shop 1: the batch is stored per shop, read from the token.
String _tokenFor(int tenantId) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'tenant_id': tenantId})}.sig';
}

BatchItem _stored(BatchItemStatus status, int job, {String? error}) => BatchItem(label: 'Bill', pages: [])
  ..sourceImages = ['1/$job.jpg']
  ..status = status
  ..lastJobId = job
  ..errorMessage = error
  ..savedInvoiceId = status == BatchItemStatus.saved ? 500 + job : null;

void main() {
  group('isFinishedOnServer', () {
    test('a bill the server has read or saved', () {
      for (final s in [BatchItemStatus.pendingConfirm, BatchItemStatus.needsReview, BatchItemStatus.saved]) {
        expect(_stored(s, 1).isFinishedOnServer, isTrue, reason: '$s');
      }
    });

    test('not while it is being uploaded or read, nor once it failed', () {
      for (final s in [
        BatchItemStatus.needsCrop,
        BatchItemStatus.preparing,
        BatchItemStatus.ready,
        BatchItemStatus.processing,
        BatchItemStatus.failed,
      ]) {
        expect(_stored(s, 1).isFinishedOnServer, isFalse, reason: '$s');
      }
    });

    test('not with no job: the server has nothing to show', () {
      final item = _stored(BatchItemStatus.pendingConfirm, 1)..lastJobId = null;
      expect(item.isFinishedOnServer, isFalse);
    });
  });

  testWidgets('cards the server finished last session are dropped at start-up, and the unsaved ones still watched',
      (tester) async {
    final stored = [
      _stored(BatchItemStatus.needsReview, 99), // a discarded retry copy: on no list at all
      _stored(BatchItemStatus.saved, 98),
      _stored(BatchItemStatus.failed, 7, error: 'Qwen 400'), // the server cannot show this one fixed
    ];
    SharedPreferences.setMockInitialValues({
      'bahi_batch_1': jsonEncode([for (final i in stored) i.toJson()]),
    });
    ApiClient.instance.token = _tokenFor(1);
    addTearDown(() => ApiClient.instance.token = null);
    // Restoring the batch sweeps the pending-photo folder: a real (empty)
    // one, since a test has no platform to ask for it.
    final dir = Directory.systemTemp.createTempSync('hand_over_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    final watched = <int>[];
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/folders') return _json([]);
      if (path == '/invoices/extract') {
        return _json({
          'jobs': [
            {'job_id': 7, 'status': 'failed', 'source_image': '1/7.jpg', 'created_at': '2026-10-08T10:00:00Z', 'issue_count': 0},
          ],
          'next_before_id': null,
          'counts': {'root': {'failed': 1}},
        });
      }
      if (req.method == 'POST' && path == '/invoices/extract/status') {
        watched.addAll([for (final id in (jsonDecode(req.body) as Map)['job_ids'] as List) id as int]);
        await Future<void>.delayed(const Duration(seconds: 25));
        return _json({'jobs': [], 'changed': false});
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      for (var i = 0; i < 12; i++) {
        // Real time too: the sweep is real file I/O, which fake time does not move.
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(BatchItemCard), findsOneWidget, reason: 'only the failed bill keeps a phone card');
      final kept = jsonDecode((await SharedPreferences.getInstance()).getString('bahi_batch_1')!) as List;
      expect([for (final j in kept) (j as Map)['lastJobId']], [7]);
      expect(watched, contains(99), reason: 'unsaved: our team may still save it');
      expect(watched, isNot(contains(98)), reason: 'saved: nothing left to watch');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => client);
  });
}
