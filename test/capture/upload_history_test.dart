import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/list_entry.dart';
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

      // One list, no headings: a file manager is a list of files, not a
      // "recent" group stacked over an "earlier" one.
      expect(find.text('Earlier uploads'), findsNothing);
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

      expect(find.text('Bills in this folder'), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      // Only this folder's bill. The fixture also holds an unfiled bill
      // (which would read "Check & save") and one filed elsewhere (a second
      // "Saved"); neither may be in the way.
      expect(find.text('Check & save'), findsNothing);
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

  group('staying where you were', () {
    // A page the test can change between calls, to stand in for the shop's
    // bills moving on the server while you look at one.
    late List<UploadSummary> server;
    late int? next;
    // Where the newest page stops. Rows below it are on the NEXT page, as
    // with the real endpoint; 0 means everything fits on the first.
    var floor = 0;

    // Honours beforeId, like the real endpoint: the next page holds only
    // what is older. A stub that ignored it served the same rows again and
    // hid a bug behind a duplicate list.
    Future<UploadPage> fetch({int limit = 50, int? beforeId}) async => UploadPage(
          uploads: server
              .where((u) => beforeId == null ? u.jobId >= floor : u.jobId < beforeId)
              .toList(),
          nextBeforeId: beforeId == null ? next : null,
        );

    Widget build(GlobalKey<UploadHistoryState> key) => _host(UploadHistory(
          key: key,
          localItems: const [],
          folderId: null,
          selected: const {},
          onOpen: (_) async {},
          fetch: fetch,
        ));

    setUp(() {
      floor = 0;
      next = null;
      server = [
        _upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3),
        _upload(jobId: 20, sourceImage: '8/20.jpg', issueCount: 2),
        _upload(jobId: 10, sourceImage: '8/10.jpg', issueCount: 1),
      ];
    });

    testWidgets('bills are in upload order, whatever order they arrive in', (tester) async {
      // Newest id first on screen — and a bill you opened is not newest.
      server = server.reversed.toList();
      await tester.pumpWidget(build(GlobalKey<UploadHistoryState>()));
      await tester.pump();

      double top(String label) => tester.getTopLeft(find.text(label)).dy;
      final order = ['Check 3', 'Check 2', 'Check 1'];
      // Same row means same dy, so compare by column within the row:
      // three across, so newest is leftmost.
      double left(String label) => tester.getTopLeft(find.text(label)).dx;
      expect(left(order[0]) < left(order[1]), isTrue);
      expect(left(order[1]) < left(order[2]), isTrue);
      expect(top(order[0]), top(order[1]));
    });

    testWidgets('a refresh never empties the list', (tester) async {
      // The server's answer is held open, so the moment BETWEEN asking and
      // being answered can be looked at. With an instant stub that moment
      // never exists, and a refresh that cleared first would pass — which
      // an earlier version of this test did.
      var hold = false;
      final release = Completer<void>();
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(_host(UploadHistory(
        key: key,
        localItems: const [],
        folderId: null,
        selected: const {},
        onOpen: (_) async {},
        fetch: ({int limit = 50, int? beforeId}) async {
          if (hold) await release.future;
          return UploadPage(uploads: List.of(server), nextBeforeId: null);
        },
      )));
      await tester.pump();
      expect(find.text('Check 2'), findsOneWidget);

      hold = true;
      final pending = key.currentState!.refresh();
      await tester.pump();
      expect(find.text('Check 2'), findsOneWidget,
          reason: 'the list was emptied while the refresh was in flight');

      release.complete();
      await pending;
      await tester.pump();
      expect(find.text('Check 2'), findsOneWidget);
    });

    testWidgets('a bill that got saved updates in place and does not move', (tester) async {
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(build(key));
      await tester.pump();
      final before = tester.getTopLeft(find.text('Check 2'));

      server[1] = _upload(jobId: 20, sourceImage: '8/20.jpg', invoiceId: 5, issueCount: 2);
      await key.currentState!.refresh();
      await tester.pump();

      expect(find.text('Check 2'), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      // Its neighbours kept their places: the saved card sits in the
      // middle column where 'Check 2' was.
      final after = tester.getTopLeft(find.text('Saved'));
      expect(after.dy, before.dy);
    });

    testWidgets('a bill that was discarded disappears', (tester) async {
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(build(key));
      await tester.pump();

      server.removeAt(1);                      // the shop threw job 20 away
      await key.currentState!.refresh();
      await tester.pump();

      expect(find.text('Check 2'), findsNothing);
      expect(find.text('Check 3'), findsOneWidget);
      expect(find.text('Check 1'), findsOneWidget);
    });

    testWidgets('a new upload arrives at the top', (tester) async {
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(build(key));
      await tester.pump();

      server.insert(0, _upload(jobId: 40, sourceImage: '8/40.jpg', issueCount: 4));
      await key.currentState!.refresh();
      await tester.pump();

      expect(find.text('Check 4'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Check 4')).dx <
          tester.getTopLeft(find.text('Check 3')).dx, isTrue);
    });

    testWidgets('asking for the next page while building does not throw', (tester) async {
      // The shop has more than one page. The last card on the page asks
      // for the next one, and that used to call setState inside the
      // builder — "setState() called during build".
      next = 10;                                 // more beyond job 10
      floor = 10;                                // the first page stops there
      server = [
        _upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3),
        _upload(jobId: 20, sourceImage: '8/20.jpg', issueCount: 2),
        _upload(jobId: 10, sourceImage: '8/10.jpg', issueCount: 1),
        _upload(jobId: 5, sourceImage: '8/5.jpg', issueCount: 9),   // the older page
      ];
      await tester.pumpWidget(build(GlobalKey<UploadHistoryState>()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Check 9'), findsOneWidget, reason: 'the next page never loaded');
    });

    testWidgets('older pages already loaded survive a refresh', (tester) async {
      // The refresh only reaches the newest page. Rows past its range are
      // not "missing" — they are just further down — and must stay.
      next = 5;                                // more beyond job 10
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(build(key));
      await tester.pump();

      server = [_upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3)];   // a shorter page
      next = 25;
      await key.currentState!.refresh();
      await tester.pump();

      expect(find.text('Check 2'), findsOneWidget, reason: 'an older row was dropped');
      expect(find.text('Check 1'), findsOneWidget);
    });
  });


  group('one list for both halves', () {
    ListEntry local(String label, int sortKey) => ListEntry(
          id: 'l:$label',
          sortKey: sortKey,
          item: BatchItem(label: label, pages: [])..lastJobId = sortKey,
          card: SizedBox(key: ValueKey('local-$label'), width: 40, height: 40, child: Text(label)),
        );

    testWidgets('a device bill sits BETWEEN shop bills, in upload order', (tester) async {
      // 30 and 10 are the shop's; 20 is held on this phone. Before, the
      // phone's bill drew above ALL of the shop's, whatever its age.
      await tester.pumpWidget(_host(_list(
        localEntries: [local('LOCAL20', 20)],
        uploads: [
          _upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3),
          _upload(jobId: 10, sourceImage: '8/10.jpg', issueCount: 1),
        ],
      )));
      await tester.pump();

      double x(Finder f) => tester.getTopLeft(f).dx;
      expect(x(find.text('Check 3')) < x(find.text('LOCAL20')), isTrue);
      expect(x(find.text('LOCAL20')) < x(find.text('Check 1')), isTrue);
    });

    testWidgets('a bill held on this phone never moves when it is opened or filed', (tester) async {
      // Its place is its job id. Re-sorting after a status change or a
      // folder change must put it back exactly where it was.
      final a = local('A', 20);
      await tester.pumpWidget(_host(_list(
        localEntries: [a],
        uploads: [_upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3)],
      )));
      await tester.pump();
      final before = tester.getTopLeft(find.text('A'));

      a.item!
        ..status = BatchItemStatus.saved
        ..folderId = null;
      await tester.pumpWidget(_host(_list(
        localEntries: [a],
        uploads: [_upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3)],
      )));
      await tester.pump();

      expect(tester.getTopLeft(find.text('A')), before);
    });

    testWidgets('reports every card, device and shop alike, in order', (tester) async {
      List<ListEntry> seen = const [];
      await tester.pumpWidget(_host(_list(
        localEntries: [local('A', 20)],
        uploads: [_upload(jobId: 30, sourceImage: '8/30.jpg'), _upload(jobId: 10, sourceImage: '8/10.jpg')],
        onEntries: (e) => seen = e,
      )));
      await tester.pumpAndSettle();

      expect(seen.map((e) => e.id), ['j:30', 'l:A', 'j:10']);
    });

    testWidgets("the phone's own bills survive the shop's list failing", (tester) async {
      // A failed fetch used to take the whole list with it, including
      // bills that live on this device and need no network at all.
      await tester.pumpWidget(_host(UploadHistory(
        localItems: const [],
        localEntries: [local('A', 20)],
        folderId: null,
        selected: const {},
        onOpen: (_) async {},
        fetch: ({int limit = 50, int? beforeId}) async => throw Exception('offline'),
      )));
      await tester.pump();
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('only "To crop" ticked hides the shop\'s half but not the phone\'s', (tester) async {
      await tester.pumpWidget(_host(_list(
        selected: const {'tocrop'},
        localEntries: [local('A', 20)],
        uploads: [_upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3)],
      )));
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
      expect(find.text('Check 3'), findsNothing);
    });

    testWidgets('reports what each box would show, before any box narrows it', (tester) async {
      // A box is TICKED ("saved"), yet the number on every box must still
      // be what ticking it would show — a count that shrinks as other boxes
      // are ticked is a count nobody can read.
      Map<String, int> seen = const {};
      await tester.pumpWidget(_host(UploadHistory(
        localItems: const [],
        folderId: null,
        selected: const {'saved'},
        onOpen: (_) async {},
        onEntries: (entries, {required more, required settled, required counts}) => seen = counts,
        // A ticked box is asked of the server: it sends only the saved bill,
        // and the tally of EVERY box — which is what the numbers say.
        fetchFiltered: ({int limit = 50, int? beforeId, Set<String> categories = const {}, String? folder}) async =>
            UploadPage(
              uploads: [_upload(jobId: 1, sourceImage: '8/1.jpg', invoiceId: 4)],
              counts: const {'root': {'review': 1, 'check': 1, 'saved': 1}},
            ),
      )));
      await tester.pumpAndSettle();

      expect(seen, {'review': 1, 'check': 1, 'saved': 1});
    });

    testWidgets("is not \"settled\" until the shop's list has answered", (tester) async {
      // An empty list that is merely still loading must not read as "no
      // bills" — that drew "Photograph a supplier bill" over a shop of 214.
      final answer = Completer<UploadPage>();
      final seen = <bool>[];
      await tester.pumpWidget(_host(UploadHistory(
        localItems: const [],
        folderId: null,
        selected: const {},
        onOpen: (_) async {},
        onEntries: (entries, {required more, required settled, required counts}) => seen.add(settled),
        fetch: ({int limit = 50, int? beforeId}) => answer.future,
      )));
      await tester.pump();
      await tester.pump();

      expect(seen, isNotEmpty, reason: 'it must report even while it has nothing to show');
      expect(seen.every((settled) => !settled), isTrue, reason: 'it said it was settled before any answer');

      answer.complete(const UploadPage(uploads: []));
      await tester.pumpAndSettle();
      expect(seen.last, isTrue, reason: 'an empty ANSWER is settled — that is a shop with no bills');
    });
  });


  group('choosing bills', () {
    final three = [
      _upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3),
      _upload(jobId: 20, sourceImage: '8/20.jpg', issueCount: 2),
      _upload(jobId: 10, sourceImage: '8/10.jpg', issueCount: 1),
    ];

    testWidgets('a tap picks the bill instead of opening it', (tester) async {
      final toggled = <String>[];
      UploadSummary? opened;
      await tester.pumpWidget(_host(_list(
        uploads: three,
        choosing: true,
        onToggle: toggled.add,
        onOpen: (u) => opened = u,
      )));
      await tester.pump();
      await tester.tap(find.text('Check 2'));
      await tester.pump();

      expect(toggled, ['j:20']);
      expect(opened, isNull, reason: 'opening and picking are different intents');
    });

    testWidgets('outside choosing, a tap still opens the bill', (tester) async {
      final toggled = <String>[];
      UploadSummary? opened;
      await tester.pumpWidget(_host(_list(
        uploads: three,
        onToggle: toggled.add,
        onOpen: (u) => opened = u,
      )));
      await tester.pump();
      await tester.tap(find.text('Check 2'));
      await tester.pump();

      expect(opened?.jobId, 20);
      expect(toggled, isEmpty);
    });

    testWidgets('every card shows a mark while choosing, and a tick only when chosen', (tester) async {
      await tester.pumpWidget(_host(_list(
        uploads: three,
        choosing: true,
        chosen: const {'j:30', 'j:10'},
      )));
      await tester.pump();

      expect(find.byKey(const ValueKey('selection-mark')), findsNWidgets(3));
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    });

    testWidgets('no marks at all when nothing is being chosen', (tester) async {
      await tester.pumpWidget(_host(_list(uploads: three)));
      await tester.pump();

      expect(find.byKey(const ValueKey('selection-mark')), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });
  });

  group('what the bulk actions do to the list', () {
    // A real list held by a key, so forget() and refile() can be called as
    // the screen calls them once the server has agreed.
    final key = GlobalKey<UploadHistoryState>();
    late List<UploadSummary> server;

    Widget build({int? folderId}) => _host(UploadHistory(
          key: key,
          localItems: const [],
          folderId: folderId,
          selected: const {},
          onOpen: (_) async {},
          fetch: ({int limit = 50, int? beforeId}) async =>
              UploadPage(uploads: List.of(server), nextBeforeId: null),
        ));

    setUp(() {
      server = [
        _upload(jobId: 30, sourceImage: '8/30.jpg', issueCount: 3),
        _upload(jobId: 20, sourceImage: '8/20.jpg', issueCount: 2),
        _upload(jobId: 10, sourceImage: '8/10.jpg', issueCount: 1),
      ];
    });

    testWidgets('forgetting a bill takes it off at once', (tester) async {
      await tester.pumpWidget(build());
      await tester.pump();
      expect(find.text('Check 2'), findsOneWidget);

      key.currentState!.forget([20]);
      await tester.pump();

      expect(find.text('Check 2'), findsNothing);
      expect(find.text('Check 3'), findsOneWidget);
      expect(find.text('Check 1'), findsOneWidget);
    });

    testWidgets('forgetting several, including ones that are not there, is harmless', (tester) async {
      await tester.pumpWidget(build());
      await tester.pump();

      key.currentState!.forget([30, 10, 999]);
      key.currentState!.forget(const []);
      await tester.pump();

      expect(find.text('Check 2'), findsOneWidget);
      expect(find.text('Check 3'), findsNothing);
    });

    testWidgets('a bill filed elsewhere leaves this folder at once', (tester) async {
      await tester.pumpWidget(build());          // home
      await tester.pump();

      key.currentState!.refile({20: 7});
      await tester.pump();

      expect(find.text('Check 2'), findsNothing, reason: 'it is in folder 7 now');
      expect(find.text('Check 3'), findsOneWidget);
    });

    testWidgets('a bill sent home arrives in the home list', (tester) async {
      server = [
        _upload(jobId: 20, sourceImage: '8/20.jpg', issueCount: 2, folderId: 7),
        _upload(jobId: 10, sourceImage: '8/10.jpg', issueCount: 1),
      ];
      await tester.pumpWidget(build());          // home
      await tester.pump();
      expect(find.text('Check 2'), findsNothing, reason: 'filed in 7, so not at home yet');

      key.currentState!.refile({20: null});      // null is home
      await tester.pump();

      expect(find.text('Check 2'), findsOneWidget);
    });
  });


  group('coming back from a bill', () {
    // The real sequence, on a list long enough to scroll: scroll down, open
    // a bill (a screen pushed over this one), close it, and let the list
    // refresh. Reported: "when I open a bill and close, I am scrolled back
    // to the top."
    List<UploadSummary> shop(int n) => [
          for (var id = n; id >= 1; id--)
            _upload(jobId: id, sourceImage: '8/$id.jpg', issueCount: id % 3),
        ];

    testWidgets('the position survives opening a bill and closing it', (tester) async {
      final controller = ScrollController();
      final key = GlobalKey<UploadHistoryState>();
      final navigator = GlobalKey<NavigatorState>();
      var server = shop(60);
      // Held open DURING the refresh, so the frame between "asked" and
      // "answered" is actually laid out. Without it a refresh that emptied
      // the list first would pass — the empty frame never exists.
      var hold = false;
      final release = Completer<void>();

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              UploadHistory(
                key: key,
                localItems: const [],
                folderId: null,
                selected: const {},
                onOpen: (_) async {},
                fetch: ({int limit = 50, int? beforeId}) async {
                  if (hold) await release.future;
                  return UploadPage(uploads: List.of(server), nextBeforeId: null);
                },
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, greaterThan(1500), reason: 'the list must scroll to mean anything');

      controller.jumpTo(1500);
      await tester.pump();
      final before = controller.offset;

      // Open a bill: another screen over this one.
      navigator.currentState!.push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('review'))));
      await tester.pumpAndSettle();
      expect(find.text('review'), findsOneWidget);

      // The bill got saved while it was open.
      server = [
        for (final u in server)
          u.jobId == 30 ? _upload(jobId: 30, sourceImage: '8/30.jpg', invoiceId: 5) : u,
      ];
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      hold = true;
      final pending = key.currentState!.refresh();
      await tester.pump();                          // mid-refresh, answer not in yet
      expect(controller.offset, before, reason: 'the list was emptied while it refreshed');

      release.complete();
      await pending;
      await tester.pumpAndSettle();

      expect(controller.offset, before, reason: 'closing a bill scrolled the list');
    });

    testWidgets('reload() DOES lose the position once the network takes real time', (tester) async {
      // This is what an older build did on return from a bill, and why it
      // reported "scrolled back to the top": reload() empties the list, the
      // request takes real time, so an EMPTY list is laid out — the offset
      // is clamped to 0 and never handed back. (With an instant fake
      // response the empty frame never happens, which is how a first
      // version of this test proved nothing.)
      final controller = ScrollController();
      final key = GlobalKey<UploadHistoryState>();
      var hold = false;
      final release = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              UploadHistory(
                key: key,
                localItems: const [],
                folderId: null,
                selected: const {},
                onOpen: (_) async {},
                fetch: ({int limit = 50, int? beforeId}) async {
                  if (hold) await release.future;
                  return UploadPage(uploads: shop(60), nextBeforeId: null);
                },
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      controller.jumpTo(1500);
      await tester.pump();
      expect(controller.offset, 1500);

      hold = true;
      final pending = key.currentState!.reload();
      await tester.pump();                      // the empty list is laid out
      release.complete();
      await pending;
      await tester.pumpAndSettle();

      // Documents the hazard rather than endorsing it: reload() is for a
      // deliberate pull-to-refresh, and the screen must never call it on
      // return from a bill — it calls refresh() instead.
      expect(controller.offset, lessThan(1500), reason: 'if this stops dropping, reload() got safer');
    });

    testWidgets("the screen re-rendering as the list reports its cards does not move it", (tester) async {
      // CaptureScreen rebuilds every time the list reports (to learn what
      // is on screen for Select all, and the counts), and hands it fresh
      // card objects each time. None of that may nudge the position.
      final controller = ScrollController();
      var rebuilds = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            return CustomScrollView(
              controller: controller,
              slivers: [
                UploadHistory(
                  localItems: const [],
                  folderId: null,
                  selected: const {},
                  onOpen: (_) async {},
                  onEntries: (entries, {required more, required settled, required counts}) =>
                      setState(() => rebuilds++),
                  fetch: ({int limit = 50, int? beforeId}) async =>
                      UploadPage(uploads: shop(60), nextBeforeId: null),
                ),
              ],
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();
      controller.jumpTo(1500);
      await tester.pumpAndSettle();

      expect(rebuilds, greaterThan(0), reason: 'the parent must actually have rebuilt');
      expect(controller.offset, 1500);
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
  List<ListEntry> localEntries = const [],
  int? folderId,
  Set<String> selected = const {},
  void Function(int)? onCount,
  void Function(List<ListEntry>)? onEntries,
  bool choosing = false,
  Set<String> chosen = const {},
  void Function(String)? onToggle,
  List<UploadSummary>? secondPage,
  void Function(UploadSummary)? onOpen,
}) {
  var served = 0;
  return UploadHistory(
    localItems: local,
    localEntries: localEntries,
    folderId: folderId,
    selected: selected,
    choosing: choosing,
    chosen: chosen,
    onToggle: onToggle,
    // `onCount` survives as a shorthand for the number of cards shown.
    onEntries: (entries, {required more, required settled, required counts}) {
      onCount?.call(entries.length);
      onEntries?.call(entries);
    },
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

