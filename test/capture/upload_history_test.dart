import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/status_filter.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/capture/widgets/upload_history.dart';

/// The shop's own bills, which the phone could not see at all until now:
/// it only ever showed what was captured on THIS device, so a reinstall
/// or a second handset showed an empty screen. One shop had 214 uploads
/// on the server and saw none of them.

UploadSummary _upload({
  int jobId = 1,
  String status = 'done',
  String sourceImage = '8/a.jpg',
  int? invoiceId,
  int? folderId,
  int issueCount = 0,
  DateTime? retryAt,
}) =>
    UploadSummary(
      jobId: jobId,
      status: status,
      sourceImage: sourceImage,
      createdAt: DateTime(2026, 10, 7, 20, 21),
      invoiceId: invoiceId,
      folderId: folderId,
      issueCount: issueCount,
      retryAt: retryAt,
    );

void main() {
  group('reading a row of the uploads list', () {
    test('takes the fields the card draws', () {
      final u = UploadSummary.fromJson({
        'job_id': 424,
        'status': 'done',
        'source_image': '8/f239.jpg',
        'created_at': '2026-10-07T14:21:13Z',
        'invoice_id': null,
        'folder_id': null,
        'issue_count': 3,
        'retry_at': null,
      });
      expect(u.jobId, 424);
      expect(u.issueCount, 3);
      expect(u.isSaved, isFalse);
    });

    test('a server that does not send issue_count reads as none, not unknown', () {
      // Older backend: the field is simply absent. It must not throw, and
      // the bill must read as clean rather than flagged.
      final u = UploadSummary.fromJson({
        'job_id': 1,
        'status': 'done',
        'source_image': '8/a.jpg',
        'created_at': '2026-10-07T14:21:13Z',
      });
      expect(u.issueCount, 0);
      expect(uploadCategory(u), 'check');
    });

    test('a page says where the next one starts', () {
      final page = UploadPage.fromJson({
        'jobs': [
          {'job_id': 2, 'status': 'done', 'source_image': '8/b.jpg', 'created_at': '2026-10-07T14:21:13Z'},
        ],
        'next_before_id': 2,
      });
      expect(page.uploads, hasLength(1));
      expect(page.nextBeforeId, 2);
    });

    test('an empty last page is not an error', () {
      final page = UploadPage.fromJson({'jobs': [], 'next_before_id': null});
      expect(page.uploads, isEmpty);
      expect(page.nextBeforeId, isNull);
    });
  });

  group('which box a server bill belongs in', () {
    test('a flagged bill is needs-review, a clean one check-and-save', () {
      expect(uploadCategory(_upload(issueCount: 3)), 'review');
      expect(uploadCategory(_upload(issueCount: 0)), 'check');
    });

    test('saved beats everything, however many issues it had', () {
      expect(uploadCategory(_upload(issueCount: 5, invoiceId: 9)), 'saved');
    });

    test('everything in flight is one category, as on the web', () {
      for (final status in ['queued', 'pending', 'processing', 'retrying']) {
        expect(uploadCategory(_upload(status: status)), 'working', reason: status);
      }
      expect(uploadCategory(_upload(retryAt: DateTime(2026, 10, 8))), 'working');
    });

    test('failed and cancelled both read as failed', () {
      expect(uploadCategory(_upload(status: 'failed')), 'failed');
      expect(uploadCategory(_upload(status: 'cancelled')), 'failed');
    });

    test('an unknown status is never silently hidden', () {
      // Every category here is a box; a row that matched none would
      // vanish the moment any box was ticked.
      final keys = kStatusFilters.map((f) => f.key).toSet();
      expect(keys, contains(uploadCategory(_upload(status: 'something-new'))));
    });

    test('filtering shows the union of what is ticked, and all of it when nothing is', () {
      final uploads = [
        _upload(jobId: 1, issueCount: 2),
        _upload(jobId: 2),
        _upload(jobId: 3, invoiceId: 7),
      ];
      expect(filterUploads(uploads, {}), hasLength(3));
      expect(filterUploads(uploads, {'review'}).map((u) => u.jobId), [1]);
      expect(filterUploads(uploads, {'review', 'saved'}).map((u) => u.jobId), [1, 3]);
    });

    test('the list is skipped when only a device-only box is ticked', () {
      // A photo waiting to be cropped has not been uploaded, so the
      // server has no row for it — no point asking.
      expect(wantsUploads({'tocrop'}), isFalse);
      expect(wantsUploads({'tocrop', 'saved'}), isTrue);
      expect(wantsUploads({}), isTrue);
    });
  });

  group('not drawing the same bill twice', () {
    test('a bill already on this device is matched by its photo path', () {
      final local = BatchItem(label: 'Bill', pages: [])..sourceImages = ['8/a.jpg'];
      final paths = {for (final i in [local]) ...i.sourceImages};

      expect(paths.contains(_upload(sourceImage: '8/a.jpg').sourceImage), isTrue);
      expect(paths.contains(_upload(sourceImage: '8/b.jpg').sourceImage), isFalse);
    });
  });

  group('the list on screen', () {
    testWidgets('draws the shop\'s bills with their status', (tester) async {
      await tester.pumpWidget(_host(_list(uploads: [
        _upload(jobId: 1, issueCount: 3),
        _upload(jobId: 2, sourceImage: '8/b.jpg'),
        _upload(jobId: 3, sourceImage: '8/c.jpg', invoiceId: 9),
      ])));
      await tester.pump();

      expect(find.text('Earlier uploads'), findsOneWidget);
      expect(find.text('Check 3'), findsOneWidget);
      expect(find.text('Check & save'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('leaves out a bill this device already holds', (tester) async {
      final local = BatchItem(label: 'Bill', pages: [])..sourceImages = ['8/a.jpg'];
      await tester.pumpWidget(_host(_list(
        local: [local],
        uploads: [
          _upload(jobId: 1, sourceImage: '8/a.jpg', issueCount: 3),   // already here
          _upload(jobId: 2, sourceImage: '8/b.jpg'),
        ],
      )));
      await tester.pump();

      expect(find.text('Check 3'), findsNothing, reason: 'drawn twice');
      expect(find.text('Check & save'), findsOneWidget);
    });

    testWidgets('shows the folder you are standing in, not the whole shop', (tester) async {
      await tester.pumpWidget(_host(_list(
        folderId: 4,
        uploads: [
          _upload(jobId: 1, sourceImage: '8/a.jpg', invoiceId: 1, folderId: 4),
          _upload(jobId: 2, sourceImage: '8/b.jpg', invoiceId: 2, folderId: 9),
          _upload(jobId: 3, sourceImage: '8/c.jpg'),                 // unfiled
        ],
      )));
      await tester.pump();

      expect(find.text('Bills in this folder'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('tells the screen how many it is showing', (tester) async {
      final counts = <int>[];
      await tester.pumpWidget(_host(_list(
        uploads: [_upload(jobId: 1), _upload(jobId: 2, sourceImage: '8/b.jpg')],
        onCount: counts.add,
      )));
      await tester.pumpAndSettle();

      // Without this the screen cannot tell "no bills at all" from "none
      // on this device", and draws the empty state over a shop's history.
      expect(counts.last, 2);
    });

    testWidgets('says nothing at all when the shop has no bills', (tester) async {
      final counts = <int>[];
      await tester.pumpWidget(_host(_list(uploads: const [], onCount: counts.add)));
      await tester.pumpAndSettle();

      expect(find.text('Earlier uploads'), findsNothing);
      expect(counts.last, 0);
    });

    testWidgets('offers to try again when the list cannot be loaded', (tester) async {
      await tester.pumpWidget(_host(UploadHistory(
        localItems: const [],
        folderId: null,
        selected: const {},
        onOpen: (_) async {},
        fetch: ({int limit = 50, int? beforeId}) async => throw Exception('offline'),
      )));
      await tester.pump();
      await tester.pump();

      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('opens the bill that was tapped', (tester) async {
      UploadSummary? opened;
      await tester.pumpWidget(_host(_list(
        uploads: [_upload(jobId: 7, issueCount: 2)],
        onOpen: (u) => opened = u,
      )));
      await tester.pump();
      await tester.tap(find.text('Check 2'));
      await tester.pump();

      expect(opened?.jobId, 7);
    });
  });
}

// ---- the list itself, driven without a network ----

Widget _host(UploadHistory list) => MaterialApp(
      home: Scaffold(body: CustomScrollView(slivers: [list])),
    );

UploadHistory _list({
  required List<UploadSummary> uploads,
  List<BatchItem> local = const [],
  int? folderId,
  Set<String> selected = const {},
  void Function(int)? onCount,
  List<UploadSummary>? secondPage,
  void Function(UploadSummary)? onOpen,
}) {
  var served = 0;
  return UploadHistory(
    localItems: local,
    folderId: folderId,
    selected: selected,
    onCount: onCount,
    onOpen: (u) async => onOpen?.call(u),
    fetch: ({int limit = 50, int? beforeId}) async {
      served++;
      if (served == 1) {
        return UploadPage(uploads: uploads, nextBeforeId: secondPage == null ? null : 99);
      }
      return UploadPage(uploads: secondPage ?? const [], nextBeforeId: null);
    },
  );

}

