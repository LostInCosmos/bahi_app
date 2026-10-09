import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/capture/widgets/upload_history.dart';

/// The number on a status box is the shop's, not "whatever has loaded".
///
/// It read "Check & save 29", then 74, as the shopkeeper scrolled, because
/// it was tallied from the pages that had arrived. A short fixture hides
/// that completely — the loaded bills ARE all the bills — so here the shop
/// has far more bills than the list holds, and the server says so.

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
  late Map<String, int> seen;
  late bool moreBelow;
  late Completer<UploadPage> secondPage;

  /// Three bills loaded, 74 + 2 on the server, a second page held back so
  /// the "more below" moment can be looked at.
  Widget list(
    GlobalKey<UploadHistoryState> key, {
    List<BatchItem> local = const [],
    int? folderId,
    Map<String, Map<String, int>>? counts = const {
      'root': {'check': 74, 'failed': 2},
      '5': {'check': 9},
    },
  }) {
    secondPage = Completer<UploadPage>();
    var served = 0;
    return _host(UploadHistory(
      key: key,
      localItems: local,
      folderId: folderId,
      selected: const {},
      onOpen: (_) async {},
      onEntries: (entries, {required more, required settled, required counts}) {
        seen = counts;
        moreBelow = more;
      },
      fetch: ({int limit = 50, int? beforeId}) {
        served++;
        if (served == 1) {
          return Future.value(UploadPage(
            uploads: [_bill(3), _bill(2), _bill(1)],
            nextBeforeId: 1,
            counts: counts,
          ));
        }
        return secondPage.future;
      },
    ));
  }

  testWidgets('says 74 while only 3 bills are loaded', (tester) async {
    await tester.pumpWidget(list(GlobalKey<UploadHistoryState>()));
    await tester.pump();
    await tester.pump();

    expect(moreBelow, isTrue);                                 // the fixture reached the bug
    expect(seen, {'check': 74, 'failed': 2});               // not {'check': 3}
  });

  testWidgets('reads the folder being looked at, not the whole shop', (tester) async {
    await tester.pumpWidget(list(GlobalKey<UploadHistoryState>(), folderId: 5));
    await tester.pump();
    await tester.pump();
    // The three loaded bills are in no folder, so none show here; the
    // number is still the folder's own.
    expect(seen, {'check': 9});
  });

  testWidgets('once every bill is loaded it counts them, live', (tester) async {
    await tester.pumpWidget(list(GlobalKey<UploadHistoryState>()));
    await tester.pump();
    await tester.pump();

    secondPage.complete(UploadPage(
      uploads: [_bill(0, status: 'failed')],
      nextBeforeId: null,
    ));
    await tester.pump();
    await tester.pump();

    expect(moreBelow, isFalse);
    expect(seen, {'check': 3, 'failed': 1});                // the server's snapshot is retired
  });

  testWidgets('discarding a bill takes one off its box at once', (tester) async {
    final key = GlobalKey<UploadHistoryState>();
    await tester.pumpWidget(list(key));
    await tester.pump();
    await tester.pump();

    key.currentState!.forget([2]);
    await tester.pump();
    await tester.pump();

    expect(seen, {'check': 73, 'failed': 2});
  });

  testWidgets('filing a bill out of home takes one off home', (tester) async {
    final key = GlobalKey<UploadHistoryState>();
    await tester.pumpWidget(list(key));
    await tester.pump();
    await tester.pump();

    key.currentState!.refile({3: 5});
    await tester.pump();
    await tester.pump();

    expect(seen, {'check': 73, 'failed': 2});
  });

  testWidgets('filing a bill into a folder adds one to that folder', (tester) async {
    final key = GlobalKey<UploadHistoryState>();
    await tester.pumpWidget(list(key, folderId: 5));
    await tester.pump();
    await tester.pump();
    expect(seen, {'check': 9});

    key.currentState!.refile({3: 5});
    await tester.pump();
    await tester.pump();

    expect(seen, {'check': 10});
  });

  testWidgets("a bill this phone holds is not counted twice", (tester) async {
    // The grid above counts the phone's own bills, and the server counts
    // them too. Bill 2 is on this phone.
    final local = BatchItem(label: 'Bill', pages: [])..sourceImages = ['8/2.jpg'];
    await tester.pumpWidget(list(GlobalKey<UploadHistoryState>(), local: [local]));
    await tester.pump();
    await tester.pump();

    expect(seen, {'check': 73, 'failed': 2});
  });

  testWidgets('a server that sends no counts still gets the loaded tally', (tester) async {
    await tester.pumpWidget(list(GlobalKey<UploadHistoryState>(), counts: null));
    await tester.pump();
    await tester.pump();
    expect(seen, {'check': 3});
  });

  test('a page reads its counts, and tolerates their absence', () {
    final page = UploadPage.fromJson({
      'jobs': [],
      'counts': {
        'root': {'check': 74},
        '5': {'saved': 2, 'review': 1},
      },
    });
    expect(page.counts, {'root': {'check': 74}, '5': {'saved': 2, 'review': 1}});
    expect(UploadPage.fromJson({'jobs': []}).counts, isNull);
  });

  group('what each folder holds', () {
    Widget totalsList(void Function(Map<int?, int>) onTotals, {GlobalKey<UploadHistoryState>? key, bool morePages = true}) {
      var served = 0;
      return _host(UploadHistory(
        key: key,
        localItems: const [],
        folderId: null,
        selected: const {},
        onOpen: (_) async {},
        onFolderTotals: onTotals,
        fetch: ({int limit = 50, int? beforeId}) {
          // One page, then — while "more" is claimed — every later page held
          // open, as a slow server would. Answering the first page again
          // would put the same bills in the list twice.
          if (++served > 1) return Completer<UploadPage>().future;
          return Future.value(UploadPage(
            uploads: [_bill(3), _bill(2, folderId: 5), _bill(1, folderId: 5)],
            nextBeforeId: morePages ? 1 : null,
            counts: const {
              'root': {'check': 70},
              '5': {'check': 200, 'saved': 4},
            },
          ));
        },
      ));
    }

    testWidgets("uses the server's tally while more bills remain, over every bill", (tester) async {
      var seenTotals = <int?, int>{};
      await tester.pumpWidget(totalsList((t) => seenTotals = t));
      await tester.pump();
      await tester.pump();

      expect(seenTotals, {null: 70, 5: 204});   // not {null: 1, 5: 2}
    });

    testWidgets('counts the bills it holds once every page is in', (tester) async {
      var seenTotals = <int?, int>{};
      await tester.pumpWidget(totalsList((t) => seenTotals = t, morePages: false));
      await tester.pump();
      await tester.pump();

      expect(seenTotals, {null: 1, 5: 2});
    });

    testWidgets('a discarded bill the server refused is counted again when it comes back', (tester) async {
      var seenTotals = <int?, int>{};
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(totalsList((t) => seenTotals = t, key: key));
      await tester.pump();
      await tester.pump();

      key.currentState!.forget([3]);
      await tester.pump();
      await tester.pump();
      expect(seenTotals, {null: 69, 5: 204});

      key.currentState!.restore([_bill(3)]);
      await tester.pump();
      await tester.pump();
      expect(seenTotals, {null: 70, 5: 204});
    });

    testWidgets('moving bills changes the totals at once', (tester) async {
      var seenTotals = <int?, int>{};
      final key = GlobalKey<UploadHistoryState>();
      await tester.pumpWidget(totalsList((t) => seenTotals = t, key: key));
      await tester.pump();
      await tester.pump();

      key.currentState!.refile({3: 5});
      await tester.pump();
      await tester.pump();

      expect(seenTotals, {null: 69, 5: 205});
    });
  });
}
