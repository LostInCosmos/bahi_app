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
import 'package:gst_bill_app/features/capture/models/hand_over.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/invoice/data/invoice_api.dart';

/// A bill added inside a folder stays in it once the shop's list takes over
/// from the phone's card (DAS-151).
///
/// Reported from production: bills uploaded inside a folder showed at Home,
/// and the shopkeeper moved each one back by hand. The upload carried no
/// folder, so the server listed it at Home, and the card handed over to that
/// row without comparing folders.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

String _tokenFor(int tenantId) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'tenant_id': tenantId})}.sig';
}

BatchItem _card(int job, int? folder, {BatchItemStatus status = BatchItemStatus.pendingConfirm}) =>
    BatchItem(label: 'Bill', pages: [])
      ..sourceImages = ['1/$job.jpg']
      ..status = status
      ..lastJobId = job
      ..folderId = folder;

UploadSummary _row(int job, int? folder) => UploadSummary(
    jobId: job, status: 'done', sourceImage: '1/$job.jpg', createdAt: DateTime(2026, 10, 30), folderId: folder);

Map<String, Object?> _rowJson(int job, int? folder, {int? invoice}) => {
      'job_id': job,
      'status': 'done',
      'source_image': '1/$job.jpg',
      'created_at': '2026-10-30T10:00:00Z',
      'issue_count': 0,
      'folder_id': folder,
      'invoice_id': invoice,
    };

void main() {
  group('splitHandOver', () {
    test('hands over only to a row in the same folder', () {
      final home = _card(1, null), inFolder = _card(2, 5);
      final split = splitHandOver([home, inFolder], [_row(1, null), _row(2, 5)]);
      expect(split.handed, [home, inFolder]);
      expect(split.refile, isEmpty);
    });

    test('a row left at Home for a card in a folder is re-filed, and the card stays', () {
      final card = _card(2, 5);
      final split = splitHandOver([card], [_row(2, null)]);
      expect(split.handed, isEmpty, reason: 'handing over here is the bug: the bill would jump to Home');
      expect([for (final m in split.refile) m.item], [card]);
    });

    test('a card moved while its upload was on its way is re-filed where it was moved to', () {
      // The upload carried folder 5; the move had no job to send, so only the
      // card knows folder 8. Following the row would undo the move.
      final card = _card(2, 8);
      final split = splitHandOver([card], [_row(2, 5)]);
      expect(split.handed, isEmpty);
      expect([for (final m in split.refile) m.item], [card]);
    });

    test('a card moved to Home is re-filed at Home', () {
      final card = _card(2, null);
      final split = splitHandOver([card], [_row(2, 5)]);
      expect([for (final m in split.refile) m.row.jobId], [2]);
    });

    test('a card not finished, or whose row is in another box, waits', () {
      final reading = _card(2, 5, status: BatchItemStatus.processing);
      final saved = _card(3, 5, status: BatchItemStatus.saved)..savedInvoiceId = 9;
      final split = splitHandOver([reading, saved], [_row(2, null), _row(3, null)]);
      expect(split.handed, isEmpty);
      expect(split.refile, isEmpty, reason: 'the row says Check & save, the card Saved: the list is behind');
    });
  });

  test('the upload carries the folder the bill was added in', () async {
    String? body;
    final client = MockClient((req) async {
      body = req.body;
      return _json({'job_id': 9});
    });
    await http.runWithClient(() async {
      await ApiClient.instance.submitExtraction('1/9.jpg', folderId: 5);
      expect(body, contains('name="folder_id"\r\n\r\n5'));
      await ApiClient.instance.submitExtraction('1/9.jpg');
      expect(body, isNot(contains('folder_id')), reason: 'Home sends no folder');
    }, () => client);
  });

  testWidgets('a bill the server lists at Home is moved into its card\'s folder, then handed over', (tester) async {
    SharedPreferences.setMockInitialValues({
      'bahi_batch_1': jsonEncode([_card(7, 5).toJson(), (_card(8, 5, status: BatchItemStatus.saved)..savedInvoiceId = 508).toJson()]),
    });
    ApiClient.instance.token = _tokenFor(1);
    addTearDown(() => ApiClient.instance.token = null);
    final dir = Directory.systemTemp.createTempSync('folder_hand_over_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    final moves = <Map>[];
    var filed = false;
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/folders') return _json([{'id': 5, 'parent_id': null, 'name': 'Cipla', 'bill_count': 0}]);
      if (req.method == 'GET' && path == '/invoices/extract') {
        // The list is fetched folder by folder, and the server files the
        // two bills at Home until they are moved.
        final asked = req.url.queryParameters['folder'] ?? 'root';
        final here = asked == (filed ? '5' : 'root');
        return _json({
          'jobs': here ? [_rowJson(7, filed ? 5 : null), _rowJson(8, filed ? 5 : null, invoice: 508)] : [],
          'next_before_id': null,
          'counts': {
            filed ? '5' : 'root': {'check': 1, 'saved': 1}
          },
        });
      }
      if (req.method == 'POST' && path == '/invoices/bulk-move') {
        final b = jsonDecode(req.body) as Map;
        moves.add(b);
        filed = true;
        return _json({'moved_jobs': b['job_ids'], 'moved_invoices': b['invoice_ids'], 'skipped': []});
      }
      if (req.method == 'POST' && path == '/invoices/extract/status') {
        await Future<void>.delayed(const Duration(seconds: 25));
        return _json({'jobs': [], 'changed': false});
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      for (var i = 0; i < 16; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(moves, [
        {'job_ids': [7], 'invoice_ids': [], 'folder_id': 5},
        {'job_ids': [], 'invoice_ids': [508], 'folder_id': 5},
      ], reason: 'the unsaved bill by its job, the saved one by its invoice; once each');
      Future<List> kept() async =>
          jsonDecode((await SharedPreferences.getInstance()).getString('bahi_batch_1') ?? '[]') as List;
      expect([for (final j in await kept()) (j as Map)['folderId']], [5, 5],
          reason: 'after a restart the cards are the only record of the folder; they stay until it is listed');

      await tester.tap(find.text('Cipla'));
      for (var i = 0; i < 16; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await kept(), isEmpty, reason: 'the folder lists them now, so the cards hand over');
      expect(moves, hasLength(2), reason: 'nothing is moved twice');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => client);
  });

  testWidgets('a re-file is tried once; then the card hands over to wherever the server lists the bill', (tester) async {
    // The other phone moved the bill to folder 8 just before this phone's
    // card handed over. This phone moves it back to 5 once — and then the
    // other phone's move again: the card must not chase it.
    SharedPreferences.setMockInitialValues({'bahi_batch_1': jsonEncode([_card(7, 5).toJson()])});
    ApiClient.instance.token = _tokenFor(1);
    addTearDown(() => ApiClient.instance.token = null);
    final dir = Directory.systemTemp.createTempSync('folder_hand_over_once');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    var moves = 0;
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/folders') {
        return _json([
          {'id': 5, 'parent_id': null, 'name': 'Cipla', 'bill_count': 0},
          {'id': 8, 'parent_id': null, 'name': 'Sun', 'bill_count': 1},
        ]);
      }
      if (req.method == 'GET' && path == '/invoices/extract') {
        final here = (req.url.queryParameters['folder'] ?? 'root') == 'root';
        return _json({
          'jobs': here ? [_rowJson(7, null)] : [],
          'next_before_id': null,
          'counts': {'root': {'check': 1}},
        });
      }
      if (req.method == 'POST' && path == '/invoices/bulk-move') {
        moves++;
        // Moved, and moved straight back by the other phone: still at Home.
        return _json({'moved_jobs': [7], 'moved_invoices': [], 'skipped': []});
      }
      if (req.method == 'POST' && path == '/invoices/extract/status') {
        await Future<void>.delayed(const Duration(seconds: 25));
        return _json({'jobs': [], 'changed': false});
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(moves, 1, reason: 'once, not once per build or per list answer');
      final kept = jsonDecode((await SharedPreferences.getInstance()).getString('bahi_batch_1') ?? '[]') as List;
      expect(kept, isEmpty, reason: 'after its one re-file the card hands over to the server\'s answer');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => client);
  });

  testWidgets('Home holding only folders still offers a photo', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = _tokenFor(1);
    addTearDown(() => ApiClient.instance.token = null);
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/folders') return _json([{'id': 5, 'parent_id': null, 'name': 'Cipla', 'bill_count': 3}]);
      if (req.method == 'GET' && path == '/invoices/extract') {
        return _json({'jobs': [], 'next_before_id': null, 'counts': {}});
      }
      return http.Response('not found', 404);
    });
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Cipla'), findsOneWidget);
      expect(find.text('Add another'), findsOneWidget, reason: 'there was no way to photograph a bill at Home');
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
}
