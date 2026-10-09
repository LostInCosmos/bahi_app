import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/list_entry.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/capture/widgets/upload_history.dart';

/// What a ticked status box draws must be what the server counts in it.
///
/// "Needs review 34" drew 24, then 39. A bill the phone also held a card for was
/// hidden twice over; a card was matched to a row by photo, so twenty cards hid
/// thirty rows (the same photo read more than once is several jobs); and a card
/// still saying "needs review" for a bill the server now had elsewhere was drawn
/// in the box anyway.

UploadSummary _bill(int id, {String status = 'done', int? folderId, int issues = 0}) => UploadSummary(
      jobId: id,
      status: status,
      sourceImage: '8/$id.jpg',
      createdAt: DateTime(2026, 10, 7, 20, 21),
      folderId: folderId,
      issueCount: issues,
    );

Widget _host(UploadHistory list) => MaterialApp(
      home: Scaffold(body: CustomScrollView(slivers: [list])),
    );

void main() {
  group('the server decides what is in a ticked box', () {
    // "Needs review 34", 39 drawn: a phone card still saying "needs review" for a
    // bill the server now has elsewhere was drawn in the box anyway.
    ListEntry card(int job) => ListEntry(
          id: 'l:$job',
          sortKey: job,
          item: BatchItem(label: 'Bill', pages: [])
            ..sourceImages = ['8/$job.jpg']
            ..lastJobId = job,
          card: SizedBox(key: ValueKey('local-$job'), width: 40, height: 40),
        );

    Widget box({required List<ListEntry> cards, required UploadPage page, void Function(Set<String>)? ids}) {
      return _host(UploadHistory(
        localItems: [for (final c in cards) c.item!],
        localEntries: cards,
        folderId: null,
        selected: const {'review'},
        onOpen: (_) async {},
        onEntries: (entries, {required more, required settled, required counts}) =>
            ids?.call({for (final e in entries) e.id}),
        fetchFiltered: ({int limit = 50, int? beforeId, Set<String> categories = const {}, String? folder}) =>
            Future.value(page),
      ));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    testWidgets("two phone cards for one job are drawn once, so the box and the list agree", (tester) async {
      var ids = <String>{};
      final twin = ListEntry(
        id: 'l:1b',
        sortKey: 1,
        item: BatchItem(label: 'Bill', pages: [])
          ..sourceImages = ['8/1.jpg']
          ..lastJobId = 1,
        card: const SizedBox(key: ValueKey('local-1b'), width: 40, height: 40),
      );
      await tester.pumpWidget(box(
        cards: [card(1), twin],
        page: UploadPage(uploads: [_bill(1, issues: 2), _bill(2, issues: 2)]),
        ids: (v) => ids = v,
      ));
      await settle(tester);

      expect(ids, {'l:1', 'j:2'}, reason: 'job 1 once, however many cards the phone holds for it');
      expect(find.byKey(const ValueKey('local-1b')), findsNothing);
    });

    testWidgets("a phone card for a bill the server has elsewhere is not drawn in the box", (tester) async {
      var ids = <String>{};
      await tester.pumpWidget(box(
        cards: [card(1), card(9)],                          // 9 says "needs review" here, not on the server
        page: UploadPage(uploads: [_bill(1, issues: 2), _bill(2, issues: 2)]),    // the server's review box: jobs 1 and 2
        ids: (v) => ids = v,
      ));
      await settle(tester);

      expect(ids, {'l:1', 'j:2'}, reason: 'job 1 by the phone\'s card, job 2 by the server\'s row, nothing for 9');
      expect(find.byKey(const ValueKey('local-9')), findsNothing);
    });

    testWidgets('while rows are still to arrive a card is kept — its row may be on another page', (tester) async {
      var ids = <String>{};
      await tester.pumpWidget(box(
        cards: [card(1), card(9)],
        page: UploadPage(uploads: [_bill(1, issues: 2), _bill(2, issues: 2)], nextBeforeId: 2),   // more to come
        ids: (v) => ids = v,
      ));
      await settle(tester);

      expect(ids, containsAll({'l:1', 'l:9'}), reason: 'not hidden on a guess');
    });
  });

  group('a bill being retried leaves the box it was in at once', () {
    testWidgets('its row is hidden although the server still lists it there', (tester) async {
      // Tapping retry: the phone's card for it is now processing (so it is not drawn
      // under Needs review) while the server's list still has it as needing review
      // until the answer comes back. It must not reappear in the meantime.
      final retrying = BatchItem(label: 'Bill', pages: [])
        ..sourceImages = ['8/1.jpg']
        ..lastJobId = 1
        ..status = BatchItemStatus.processing;
      var ids = <String>{};
      await tester.pumpWidget(_host(UploadHistory(
        localItems: [retrying],
        localEntries: const [],                           // processing: not in the review box
        folderId: null,
        selected: const {'review'},
        onOpen: (_) async {},
        onEntries: (entries, {required more, required settled, required counts}) =>
            ids = {for (final e in entries) e.id},
        fetchFiltered: ({int limit = 50, int? beforeId, Set<String> categories = const {}, String? folder}) =>
            Future.value(UploadPage(uploads: [_bill(1, issues: 2), _bill(2, issues: 2)])),
      )));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      expect(ids, {'j:2'}, reason: 'job 1 is being retried: gone from the box; job 2 stays');
    });
  });
}
