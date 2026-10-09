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

/// Any sliver in a scroll view — for tests that wrap the list in something
/// that rebuilds it, as the screen does when a status box is ticked.
Widget _hostAny(Widget sliver) => MaterialApp(
      home: Scaffold(body: CustomScrollView(slivers: [sliver])),
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

  testWidgets("the server's tally already holds this phone's bills, and says so", (tester) async {
    // The tally counts every bill that has reached the server, this phone's
    // included — so nothing held here may be added to it again. The screen
    // reads the flag to add only the bills that have not reached the server.
    final key = GlobalKey<UploadHistoryState>();
    final local = BatchItem(label: 'Bill', pages: [])..sourceImages = ['8/2.jpg'];
    await tester.pumpWidget(list(key, local: [local]));
    await tester.pump();
    await tester.pump();

    expect(seen, {'check': 74, 'failed': 2}, reason: 'the whole-shop tally, untouched');
    expect(key.currentState!.countsCoverDeviceBills, isTrue);
  });

  testWidgets('once every bill is loaded the list counts them itself, and does not claim to cover the phone',
      (tester) async {
    final key = GlobalKey<UploadHistoryState>();
    await tester.pumpWidget(list(key));
    await tester.pump();
    await tester.pump();
    secondPage.complete(UploadPage(uploads: [_bill(0, status: 'failed')], nextBeforeId: null));
    await tester.pump();
    await tester.pump();

    expect(key.currentState!.countsCoverDeviceBills, isFalse);
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

  group('a status box asks the server', () {
    // "Failed 1" sat over "Nothing here matches": the one failed bill was on
    // a page nobody had scrolled to, and filtering the pages already loaded
    // could not find it. The box now asks for exactly its bills.
    late List<String> asked;
    late ValueNotifier<Set<String>> selected;
    late ValueNotifier<int?> folder;
    var shown = <int>[];
    var shownCounts = <String, int>{};

    Widget host({Future<UploadPage> Function()? filteredAnswer}) {
      asked = [];
      shown = [];
      shownCounts = {};
      selected = ValueNotifier<Set<String>>({});
      folder = ValueNotifier<int?>(null);
      return _hostAny(ValueListenableBuilder<Set<String>>(
        valueListenable: selected,
        builder: (context, boxes, _) => ValueListenableBuilder<int?>(
          valueListenable: folder,
          builder: (context, folderId, _) => UploadHistory(
            localItems: const [],
            folderId: folderId,
            selected: boxes,
            onOpen: (_) async {},
            onEntries: (entries, {required more, required settled, required counts}) {
              shown = [for (final e in entries) e.upload!.jobId];
              shownCounts = counts;
            },
            fetch: ({int limit = 50, int? beforeId}) {
              // One page, then every later page held open, as a slow server
              // would. Answering the first page again would put the same
              // bills in the list twice. Only first pages are recorded: the
              // list asking for the next one as it nears the end is not what
              // these tests are about.
              if (beforeId != null) return Completer<UploadPage>().future;
              asked.add('all');
              return Future.value(UploadPage(
                uploads: [_bill(3), _bill(2), _bill(1)],
                nextBeforeId: 1,
                counts: const {'root': {'check': 70, 'failed': 1}},
              ));
            },
            fetchFiltered: ({int limit = 50, int? beforeId, Set<String> categories = const {}, String? folder}) {
              asked.add('${(categories.toList()..sort()).join('+')}@$folder');
              if (filteredAnswer != null) return filteredAnswer();
              return Future.value(UploadPage(
                uploads: [_bill(0, status: 'failed')],
                counts: const {'root': {'check': 70, 'failed': 1}},
              ));
            },
          ),
        ),
      ));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    testWidgets('ticking a box fetches that box, and finds a bill on a page nobody loaded', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(shown, [3, 2, 1], reason: 'unticked, the shop is loaded as before');

      selected.value = {'failed'};
      await settle(tester);

      expect(asked, ['all', 'failed@root']);
      expect(shown, [0], reason: 'bill 0 was never in the pages that were loaded');
    });

    testWidgets('unticking goes back to the whole shop', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      selected.value = {'failed'};
      await settle(tester);

      selected.value = {};
      await settle(tester);

      expect(asked, ['all', 'failed@root', 'all']);
      expect(shown, [3, 2, 1]);
    });

    testWidgets("a device-only box is not something to ask the server", (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);

      selected.value = {'tocrop'};
      await settle(tester);

      expect(asked, ['all'], reason: "'to crop' exists only on this phone");
    });

    testWidgets('the numbers on the boxes stay the whole shops while the list is narrowed', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);

      selected.value = {'failed'};
      await settle(tester);

      // The list holds one bill, and every page is in; counting what it
      // holds would say {failed: 1} and wipe the other boxes.
      expect(shownCounts, {'check': 70, 'failed': 1});
    });

    testWidgets('changing folders while narrowed asks again; unnarrowed it does not', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      folder.value = 5;
      await settle(tester);
      expect(asked, ['all'], reason: 'unnarrowed, a folder is only a view of what is held');

      selected.value = {'failed'};
      await settle(tester);
      folder.value = 9;
      await settle(tester);

      expect(asked, ['all', 'failed@5', 'failed@9']);
    });

    testWidgets('the numbers hold still while a ticked box is being fetched', (tester) async {
      // Ticking "Needs review" made the boxes show 13 for as long as the
      // request took: the tally was thrown away, so they counted the few
      // bills loaded so far. The server's count of the shop does not change
      // with the filter, so neither may the numbers.
      final slow = Completer<UploadPage>();
      await tester.pumpWidget(host(filteredAnswer: () => slow.future));
      await settle(tester);
      expect(shownCounts, {'check': 70, 'failed': 1});

      selected.value = {'failed'};          // the request is now in flight
      await settle(tester);
      expect(shownCounts, {'check': 70, 'failed': 1}, reason: 'not counted from the bills loaded so far');

      selected.value = {};                   // and unticking, while it is still in flight
      await settle(tester);
      expect(shownCounts, {'check': 70, 'failed': 1});

      slow.complete(UploadPage(uploads: [_bill(0, status: 'failed')]));
      await settle(tester);
    });

    testWidgets('the grid does not blank while a ticked box is being fetched', (tester) async {
      // Ticking a box cleared the grid until the server answered, then filled
      // it — a flash of empty on every tick. The view that was there stays
      // until the new rows replace it in one step.
      final slow = Completer<UploadPage>();
      await tester.pumpWidget(host(filteredAnswer: () => slow.future));
      await settle(tester);
      expect(shown, [3, 2, 1]);

      selected.value = {'failed'};          // the request is in flight
      await settle(tester);
      expect(shown, [3, 2, 1], reason: 'not blank, and not the held rows re-filtered to nothing');

      slow.complete(UploadPage(uploads: [_bill(0, status: 'failed')]));
      await settle(tester);
      expect(shown, [0], reason: 'then the new view, in one step');
    });

    testWidgets("an answer to the old box is not added to the new one", (tester) async {
      final slow = Completer<UploadPage>();
      await tester.pumpWidget(host(filteredAnswer: () => slow.future));
      await settle(tester);

      selected.value = {'failed'};          // asks, and the answer is slow
      await settle(tester);
      selected.value = {};                   // changes its mind
      await settle(tester);
      slow.complete(UploadPage(uploads: [_bill(0, status: 'failed')]));
      await settle(tester);

      expect(shown, [3, 2, 1], reason: 'the failed bill belongs to a question nobody is asking now');
    });
  });

  group('searching a folder with more pages', () {
    // Search is on the phone, so it can only see bills that are loaded. While
    // someone is searching the list keeps loading the rest — the same pages a
    // scroll would fetch — so the search covers the whole folder.
    Widget list(String query, List<int?> asked) => _host(UploadHistory(
          localItems: const [],
          folderId: null,
          selected: const {},
          query: query,
          onOpen: (_) async {},
          fetch: ({int limit = 50, int? beforeId}) {
            asked.add(beforeId);
            if (beforeId != null) return Completer<UploadPage>().future;   // held open: only the ask matters
            return Future.value(UploadPage(
              uploads: [for (var i = 60; i > 30; i--) _bill(i)],           // thirty cards fill the screen
              nextBeforeId: 31,
            ));
          },
        ));

    testWidgets('asks for the next page while a search is on', (tester) async {
      final asked = <int?>[];
      await tester.pumpWidget(list('zz', asked));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(asked, [null, 31]);
    });

    testWidgets('does not, when nothing is being searched and the screen is full', (tester) async {
      final asked = <int?>[];
      await tester.pumpWidget(list('', asked));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(asked, [null], reason: 'a scroll asks for more; nothing else should');
    });
  });
}

