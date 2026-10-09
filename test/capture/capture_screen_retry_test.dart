import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/capture/widgets/status_filter_bar.dart';

/// Trying again on a bill that failed.
///
/// Reported: "after three bills at once each failed with timeout, and now no
/// retry buttons". A bill that failed on the SHOP'S list (not held by this
/// phone) said "that bill has not finished being read yet" when tapped — not
/// true, and no way to try again — and a phone's own bill whose upload failed
/// had no ↻ button because the button needed an uploaded photo.

http.Response _json(Object body, [int status = 200, String? category]) {
  // A server that honours `category=`, as the real one does.
  if (category != null && body is Map && body['jobs'] is List) {
    final keep = {
      'failed': (Map j) => j['status'] == 'failed',
      'review': (Map j) => j['status'] == 'done' && (j['issue_count'] as int) > 0,
      'check': (Map j) => j['status'] == 'done' && (j['issue_count'] as int) == 0 && j['invoice_id'] == null,
    };
    final wanted = category.split(',');
    body = {
      ...body,
      'jobs': [
        for (final j in body['jobs'] as List)
          if (wanted.any((c) => keep[c]!(j as Map))) j,
      ],
    };
  }
  return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}

BatchItem _item(BatchItemStatus status, {bool uploaded = true}) {
  final item = BatchItem(label: 'Bill', pages: [])..status = status;
  if (uploaded) item.sourceImages = ['8/1.jpg'];
  return item;
}

class _Server {
  /// Bills filed in folder 3 ("Testing2"), as on the phone, so the status
  /// boxes — which only show inside a folder — are reachable.
  _Server({this.filed = false, this.finishes = false, this.neverFinishes = false});

  /// The server keeps answering "still processing" for bill 8, as a held
  /// long-poll would, for as long as the test lets time run.
  final bool neverFinishes;

  /// How many times the screen asked about the bills in flight.
  int statusPolls = 0;

  final bool filed;

  /// Job 8 is finished by the time the screen asks about it, as the server's
  /// four-call read is when a retried bill comes back.
  final bool finishes;

  /// Job ids the screen asked to discard, and whether the server refuses.
  final discarded = <int>[];
  bool refuseDiscard = false;

  /// Where bill 8 is in its retry: `idle`, `retrying` (queued at the server),
  /// or `finished`. The server's counts and list follow it.
  String phase = 'idle';

  /// Held so a test can look at the screen before the server's status answer.
  Completer<void>? statusGate;

  /// Holds the answer to the retry request, so a test can look at the screen
  /// before the server has said anything about it.
  Completer<void>? retryGate;
  final requests = <String>[];

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        requests.add('${req.method} $path${req.url.query.isEmpty ? '' : '?${req.url.query}'}');
        if (req.method == 'GET' && path == '/folders') {
          return _json(filed ? [{'id': 3, 'parent_id': null, 'name': 'Testing2', 'bill_count': 0}] : []);
        }
        if (req.method == 'GET' && path == '/invoices/extract') {
          final asked = req.url.queryParameters['category'];
          Map<String, dynamic> job(Map<String, dynamic> j) => filed ? {...j, 'folder_id': 3} : j;
          return _json({
            'jobs': [for (final j in [
              {'job_id': 11, 'status': 'processing', 'source_image': '8/11.jpg', 'created_at': '2026-10-08T14:00:00Z', 'issue_count': 0},
              {'job_id': 10, 'status': 'done', 'source_image': '8/10.jpg', 'created_at': '2026-10-08T13:00:00Z', 'issue_count': 0, 'invoice_id': 55},
              {'job_id': 9, 'status': 'done', 'source_image': '8/9.jpg', 'created_at': '2026-10-08T12:00:00Z', 'issue_count': 0},
              {'job_id': 8, 'status': phase == 'retrying' ? 'queued' : 'done', 'source_image': '8/8.jpg', 'created_at': '2026-10-08T11:00:00Z', 'issue_count': 2},
              {
                'job_id': 7,
                'status': 'failed',
                'source_image': '8/7.jpg',
                'created_at': '2026-10-08T10:00:00Z',
                'issue_count': 0,
              },
            ]) job(j)],
            'next_before_id': null,
            'counts': {
              filed ? '3' : 'root': phase == 'retrying'
                  ? {'failed': 1, 'working': 1, 'check': 1}
                  : {'failed': 1, 'review': 1, 'check': 1},
            },
          }, 200, asked);
        }
        if (req.method == 'POST' && path == '/invoices/bulk-discard') {
          final ids = [for (final id in (jsonDecode(req.body) as Map)['job_ids'] as List) id as int];
          discarded.addAll(ids);
          return _json({'discarded': refuseDiscard ? [] : ids, 'skipped': []});
        }
        if (req.method == 'GET' && path == '/invoices/extract/7') {
          return _json({
            'job_id': 7,
            'status': 'failed',
            'error': {'kind': 'attempts_exhausted', 'message': 'Qwen timed out reading this bill'},
          });
        }
        if (req.method == 'POST' && path == '/invoices/extract/7/retry') return _json({'job_id': 7});
        if (req.method == 'POST' && path == '/invoices/extract/8/retry') {
          if (retryGate != null) await retryGate!.future;
          phase = 'retrying';
          return _json({'job_id': 8});
        }
        if (neverFinishes && req.method == 'POST' && path == '/invoices/extract/status') {
          statusPolls++;
          await Future<void>.delayed(const Duration(seconds: 25));
          return _json({
            'jobs': [{'job_id': 8, 'status': 'processing', 'attempt': 1, 'max_attempts': 3}],
            'changed': false,
          });
        }
        if (finishes && req.method == 'GET' && path == '/invoices/extract/8') {
          return _json({
            'job_id': 8,
            'status': 'done',
            'result': {
              'invoice': {
                'seller_name': 'ACME', 'seller_gstin': '09AAGCP8428E1Z7', 'invoice_no': 'A-8',
                'invoice_date': '2026-08-01', 'line_items': [], 'totals': {},
              },
              'extraction_meta': {'source_image': '8/8.jpg', 'method': 'llm'},
              'issues': [
                {'field': 'totals.grand_total', 'severity': 'error', 'message': 'totals do not add up'},
              ],
            },
          });
        }
        if (finishes && req.method == 'POST' && path == '/invoices/extract/status') {
          if (statusGate != null) await statusGate!.future;
          phase = 'finished';
          return _json({
            'jobs': [{'job_id': 8, 'status': 'done', 'attempt': 1, 'max_attempts': 3}],
            'changed': true,
          });
        }
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

  group('a bill the phone gave up on', () {
    // "Failed" over a bill the server had finished: the phone stopped waiting
    // after 120 seconds, and a bill is now up to four model calls.
    test('is recognised by the words it carries and the job it can still ask about', () {
      final item = _item(BatchItemStatus.failed)
        ..errorMessage = BatchItem.timedOutMessage
        ..lastJobId = 7;
      expect(item.failedByTimeout, isTrue);
    });

    test('a bill that failed for a real reason is not one of them', () {
      final item = _item(BatchItemStatus.failed)
        ..errorMessage = 'Qwen 400'
        ..lastJobId = 7;
      expect(item.failedByTimeout, isFalse);
    });

    test('nor is one with no job to ask about', () {
      final item = _item(BatchItemStatus.failed)..errorMessage = BatchItem.timedOutMessage;
      expect(item.failedByTimeout, isFalse);
    });

    test('nor one that is not failed', () {
      final item = _item(BatchItemStatus.processing)
        ..errorMessage = BatchItem.timedOutMessage
        ..lastJobId = 7;
      expect(item.failedByTimeout, isFalse);
    });
  });

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

      await tester.tap(find.byKey(const ValueKey('j:7')));
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

      await tester.tap(find.byKey(const ValueKey('j:7')));
      await _settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await _settle(tester);

      expect(server.requests.where((r) => r.contains('/retry')), isEmpty);
    }, () => server.client);
  });

  testWidgets('a bill that needs review can be read again from its card', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);

      final review = find.byKey(const ValueKey('j:8'));
      await tester.tap(find.descendant(of: review, matching: find.byIcon(Icons.refresh_rounded)));
      await _settle(tester);

      expect(server.requests, contains('POST /invoices/extract/8/retry'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);
  });

  testWidgets('failed and needs-review cards wear the button; a clean one does not', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);

      bool wears(String id) => find
          .descendant(of: find.byKey(ValueKey(id)), matching: find.byIcon(Icons.refresh_rounded))
          .evaluate()
          .isNotEmpty;
      expect(wears('j:7'), isTrue, reason: 'failed');
      expect(wears('j:8'), isTrue, reason: 'needs review');
      expect(wears('j:9'), isFalse, reason: 'check & save: nothing to second-guess');

      // Not while choosing.
      await tester.tap(find.text('Select'));
      await _settle(tester);
      expect(wears('j:7'), isFalse);
      expect(wears('j:8'), isFalse);
    }, () => server.client);
  });

  testWidgets('ticking Failed shows the failed bill — asked of the server, from a list that has it', (tester) async {
    _ignoreOverflow();
    final server = _Server(filed: true);
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);
      await tester.tap(find.text('Testing2'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('j:9')), findsOneWidget, reason: 'unticked, the clean bill is there');

      // The filter row scrolls sideways; at phone width "Failed" is off the
      // right edge, and a tap on it there silently hits nothing.
      final chip = find.descendant(of: find.byType(FilterChip), matching: find.textContaining('Failed'));
      await tester.scrollUntilVisible(
        chip,
        200,
        scrollable: find.descendant(of: find.byType(StatusFilterBar), matching: find.byType(Scrollable)).first,
      );
      await tester.pump();
      await tester.tap(chip);
      await _settle(tester);

      expect(server.requests.where((r) => r.startsWith('GET /invoices/extract?')).toList(), contains(contains('category=failed')),
          reason: 'the box must be asked of the server: ${server.requests}');
      expect(find.byKey(const ValueKey('j:7')), findsOneWidget, reason: 'the failed bill must be shown');
      expect(find.byKey(const ValueKey('j:9')), findsNothing);
      expect(find.textContaining('Nothing here'), findsNothing);
    }, () => server.client);
  });

  testWidgets('when a retried bill finishes the screen asks for fresh numbers', (tester) async {
    // Ten bills retried together left "Working 10" over an empty list long
    // after the server had finished them: the boxes show the server's tally,
    // which only moves when it is asked again.
    _ignoreOverflow();
    final server = _Server(filed: true, finishes: true);
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);
      await tester.tap(find.text('Testing2'));
      await _settle(tester);
      int lists() => server.requests.where((r) => r.startsWith('GET /invoices/extract?')).length;
      final before = lists();

      final review = find.byKey(const ValueKey('j:8'));
      await tester.tap(find.descendant(of: review, matching: find.byIcon(Icons.refresh_rounded)));
      await _settle(tester);
      await _settle(tester);

      expect(server.requests, contains('POST /invoices/extract/8/retry'));
      // One refresh straight after the retry, one more when it finished.
      expect(lists() - before, greaterThanOrEqualTo(2), reason: server.requests.toString());

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);
  });

  testWidgets('the box numbers move live both ways: a retry starts (Working +1) and it finishes (Working -1)', (tester) async {
    // "When a bill moves from Working to Needs review, Working goes down by one
    // and Needs review up by one — and when a retry starts, the reverse." As it
    // happens, not on the next fetch. Changes that do not involve Working wait
    // for the server.
    _ignoreOverflow();
    final server = _Server(filed: true, finishes: true)
      ..statusGate = Completer<void>()
      ..retryGate = Completer<void>();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);
      await tester.tap(find.text('Testing2'));
      await _settle(tester);
      await tester.tap(find.textContaining('Needs review 1'));   // the server's tally now
      await _settle(tester);
      expect(find.textContaining('Needs review 1'), findsOneWidget);

      final review = find.byKey(const ValueKey('j:8'));
      await tester.tap(find.descendant(of: review, matching: find.byIcon(Icons.refresh_rounded)));
      await tester.pump();
      await tester.pump();                                       // the server has not answered the retry
      expect(find.textContaining('Working 1'), findsOneWidget, reason: 'a retry began: Working +1 at once');
      expect(find.textContaining('Needs review 1'), findsNothing, reason: 'and Needs review -1');
      expect(find.textContaining('Working 2'), findsNothing);

      server.retryGate!.complete();                              // the server agrees (queued)
      await _settle(tester);
      expect(find.textContaining('Working 1'), findsOneWidget);

      server.statusGate!.complete();                             // the read finishes
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));       // well inside the 800 ms before any refetch
      expect(find.textContaining('Needs review 1'), findsOneWidget, reason: 'finished: Needs review +1');
      expect(find.textContaining('Working 1'), findsNothing, reason: 'and Working -1');

      await _settle(tester);                                     // the refetch confirms it
      expect(find.textContaining('Needs review 1'), findsOneWidget);
      expect(find.textContaining('Working 1'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);
  });

  group('the ✕ on a bill', () {
    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);
    }

    Finder cross(String id) =>
        find.descendant(of: find.byKey(ValueKey(id)), matching: find.byIcon(Icons.close_rounded));

    testWidgets('every processed bill wears one — failed included — and none that is being read', (tester) async {
      _ignoreOverflow();
      final server = _Server();
      await http.runWithClient(() async {
        await open(tester);
        // failed, needs review, clean, saved
        for (final id in ['j:7', 'j:8', 'j:9', 'j:10']) {
          expect(cross(id), findsOneWidget, reason: id);
        }
        // still being read: a worker is holding it
        expect(cross('j:11'), findsNothing);
        // Not while choosing: tapping a card chooses it then.
        await tester.tap(find.text('Select'));
        await _settle(tester);
        expect(cross('j:9'), findsNothing);
      }, () => server.client);
    });

    testWidgets('on a clean bill it removes it at once, in one request', (tester) async {
      _ignoreOverflow();
      final server = _Server();
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(cross('j:9'));
        await _settle(tester);
        expect(server.discarded, [9]);
        expect(find.byKey(const ValueKey('j:9')), findsNothing);
      }, () => server.client);
    });

    testWidgets('a bill the server refuses comes back, with a reason', (tester) async {
      _ignoreOverflow();
      final server = _Server()..refuseDiscard = true;
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(cross('j:9'));
        await _settle(tester);
        expect(find.byKey(const ValueKey('j:9')), findsOneWidget);
        expect(find.textContaining("Couldn't remove that bill"), findsOneWidget);
      }, () => server.client);
    });

    testWidgets('on a saved bill it explains instead of deleting', (tester) async {
      _ignoreOverflow();
      final server = _Server();
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(cross('j:10'));
        await _settle(tester);
        expect(server.discarded, isEmpty);
        expect(find.textContaining('This bill is saved'), findsOneWidget);
        expect(find.byKey(const ValueKey('j:10')), findsOneWidget);
      }, () => server.client);
    });

    testWidgets('on a failed bill it removes it, like any processed one', (tester) async {
      _ignoreOverflow();
      final server = _Server();
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(cross('j:7'));
        await _settle(tester);
        expect(server.discarded, [7]);
        expect(find.byKey(const ValueKey('j:7')), findsNothing);
      }, () => server.client);
    });
  });

  group('what a bill saved from last session needs at startup', () {
    // The old 120 s limit marked bills failed while the server went on to
    // finish them; those red cards were stored on the phone and stayed, over a
    // server with one failed bill, not four.
    test('a bill the phone gave up on is checked with the server, not re-read', () {
      final item = _item(BatchItemStatus.failed)
        ..errorMessage = BatchItem.timedOutMessage
        ..lastJobId = 8;
      expect(item.startupAction, StartupAction.askServer);
    });

    test('a bill that failed for a real reason is left for the shopkeeper', () {
      final item = _item(BatchItemStatus.failed)
        ..errorMessage = 'Qwen 400'
        ..lastJobId = 8;
      expect(item.startupAction, StartupAction.none);
    });

    test('a bill that was being read has its job watched, not resubmitted', () {
      final item = _item(BatchItemStatus.processing)..jobId = 8;
      expect(item.startupAction, StartupAction.resumeJob);
    });

    test('a bill never submitted is submitted; a photo never uploaded is uploaded', () {
      expect(_item(BatchItemStatus.ready).startupAction, StartupAction.process);
      expect(_item(BatchItemStatus.preparing, uploaded: false).startupAction, StartupAction.uploadAgain);
    });
  });

  testWidgets('the phone keeps watching a bill the server is still reading, with no cutoff', (tester) async {
    // It used to stop after a fixed time — 120 s, then 15 min — and mark the
    // bill failed while the server went on to finish it. There is no limit now:
    // the card shows what the server says, however long that takes.
    //
    // What this can and cannot show: fake time moves the holds and timers but
    // not DateTime.now(), so it cannot prove a clock-based cutoff is absent —
    // that is the code (no such check exists). It does show the watch never
    // stops, and the card is never turned into a failure by anything but the
    // server.
    _ignoreOverflow();
    final server = _Server(filed: true, neverFinishes: true);
    await http.runWithClient(() async {
      // Wide enough that every status box is built; the row builds lazily.
      await tester.binding.setSurfaceSize(const Size(1400, 1600));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);
      await tester.tap(find.text('Testing2'));
      await _settle(tester);
      expect(find.textContaining('Failed 1'), findsOneWidget);          // bill 7, a real failure

      final retry = find.descendant(
          of: find.byKey(const ValueKey('j:8')), matching: find.byIcon(Icons.refresh_rounded));
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await _settle(tester);
      expect(server.requests, contains('POST /invoices/extract/8/retry'), reason: 'the retry must have started');

      for (var i = 0; i < 400; i++) {
        await tester.pump(const Duration(seconds: 27));
      }

      expect(server.statusPolls, greaterThan(300), reason: 'the watch must not have stopped');
      expect(find.textContaining('Failed 1'), findsOneWidget, reason: 'still just the one real failure');
      expect(find.textContaining('Failed 2'), findsNothing);
      expect(find.textContaining('taking longer'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);
  });
}
