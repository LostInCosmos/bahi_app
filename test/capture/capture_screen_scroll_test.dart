import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';

/// The real Capture screen, driven through the reported steps: scroll down,
/// open a bill, go back. "I am scrolled back to the top."
///
/// The server is faked at the HTTP layer, so everything the screen does
/// around the list — folders loading, the status loop, its own rebuilds —
/// runs for real. An earlier test of the list ALONE passed while the
/// reported bug was still there, because the cause was somewhere around it.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _upload(int id, {int issues = 0}) => {
      'job_id': id,
      'status': 'done',
      'source_image': '8/$id.jpg',
      'created_at': '2026-10-08T10:00:00Z',
      'issue_count': issues,
    };

Map<String, dynamic> _job(int id) => {
      'job_id': id,
      'status': 'done',
      'result': {
        'invoice': {
          'seller_name': 'ACME', 'seller_gstin': '09AAGCP8428E1Z7', 'invoice_no': 'A-$id',
          'invoice_date': '2026-08-01', 'line_items': [], 'totals': {},
        },
        'extraction_meta': {'source_image': '8/$id.jpg', 'method': 'llm'},
        'issues': [
          {'field': 'totals.grand_total', 'severity': 'error', 'message': "totals do not add up"},
        ],
      },
    };

MockClient _server({int bills = 60, void Function(String)? seen}) => MockClient((req) async {
      final path = req.url.path;
      seen?.call('${req.method} $path');
      if (req.method == 'GET' && path == '/folders') return _json([]);
      if (req.method == 'GET' && path == '/invoices/extract') {
        // Paged like the real endpoint: newest first, `limit` a page, keyset
        // on before_id. A single page hid the code that runs once a shop
        // has more than fifty bills — which is exactly the shop reporting
        // this, with 334.
        final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 50;
        final before = int.tryParse(req.url.queryParameters['before_id'] ?? '') ?? (bills + 1);
        final ids = [for (var id = bills; id >= 1; id--) if (id < before) id].take(limit + 1).toList();
        final more = ids.length > limit;
        final page = ids.take(limit).toList();
        return _json({
          'jobs': [for (final id in page) _upload(id, issues: id % 3 == 1 ? 1 : 0)],
          'next_before_id': more ? page.last : null,
        });
      }
      final one = RegExp(r'^/invoices/extract/(\d+)$').firstMatch(path);
      if (req.method == 'GET' && one != null) return _json(_job(int.parse(one.group(1)!)));
      if (path == '/invoices/vendor-lookup') {
        return _json({'vendor_known': false, 'verified': false, 'needs_confirmation': true, 'gstin': ''});
      }
      return http.Response('not found', 404);   // photos and anything else
    });

Finder get _scroller => find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;

Future<void> _settle(WidgetTester tester) async {
  // Not pumpAndSettle: thumbnails keep a spinner turning, so it never settles.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}


/// The test's placeholder font is wider than a real one, so the app-bar title
/// overflows at phone width. That is the test font, not the app, and would
/// otherwise fail every test that mounts the whole shell. Called INSIDE a
/// test: testWidgets installs its own error handler after setUp, so one set
/// in setUp is silently replaced and never runs.
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

  testWidgets('scroll down, open a bill, go back: the list is where it was', (tester) async {
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CaptureScreen(onBatchFinished: () {})),
      ));
      await _settle(tester);

      final position = tester.state<ScrollableState>(_scroller).position;
      expect(position.maxScrollExtent, greaterThan(1500), reason: 'the list must be long enough to scroll');
      position.jumpTo(1500);
      await _settle(tester);
      final before = tester.state<ScrollableState>(_scroller).position.pixels;
      expect(before, 1500);

      // Open a bill that has something to check: the review screen.
      final card = find.textContaining('Check ').hitTestable().first;
      await tester.tap(card);
      await _settle(tester);
      expect(find.byType(CaptureScreen).hitTestable(), findsNothing, reason: 'a bill should have opened over the list');

      // Go back.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);

      expect(find.byType(CaptureScreen), findsOneWidget);
      expect(tester.state<ScrollableState>(_scroller).position.pixels, before,
          reason: 'going back from a bill scrolled the list');
    }, () => _server());
  });
  testWidgets('the same, inside the real app shell with all its tabs', (tester) async {
    _ignoreOverflow();
    // Capture does not live alone: it is one tab of five in an IndexedStack
    // under a Scaffold with an app bar and a navigation bar, and every tab
    // is mounted at once.
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      final position = tester.state<ScrollableState>(_scroller).position;
      expect(position.maxScrollExtent, greaterThan(1500));
      position.jumpTo(1500);
      await _settle(tester);
      final before = tester.state<ScrollableState>(_scroller).position.pixels;
      expect(before, 1500);

      await tester.tap(find.textContaining('Check ').hitTestable().first);
      await _settle(tester);
      expect(find.byType(CaptureScreen).hitTestable(), findsNothing);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);

      expect(tester.state<ScrollableState>(_scroller).position.pixels, before,
          reason: 'going back from a bill scrolled the list');
    }, () => _server());
  });

  testWidgets('334 bills: scroll deep through several pages, open one, go back', (tester) async {
    _ignoreOverflow();
    // The reported case. Scrolling this far makes the list fetch page after
    // page, so on return it is holding several pages and refreshing the
    // newest — the path a single page never touches.
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      // Scroll to the bottom repeatedly: each arrival triggers the next page.
      for (var i = 0; i < 12; i++) {
        final position = tester.state<ScrollableState>(_scroller).position;
        position.jumpTo(position.maxScrollExtent);
        await _settle(tester);
      }
      final position = tester.state<ScrollableState>(_scroller).position;
      expect(position.maxScrollExtent, greaterThan(15000), reason: 'later pages should have loaded');
      final target = position.maxScrollExtent * 0.6;
      position.jumpTo(target);
      await _settle(tester);
      final before = tester.state<ScrollableState>(_scroller).position.pixels;
      expect(before, closeTo(target, 1));

      await tester.tap(find.textContaining('Check ').hitTestable().first);
      await _settle(tester);
      expect(find.byType(CaptureScreen).hitTestable(), findsNothing, reason: 'a bill should have opened');

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);

      expect(tester.state<ScrollableState>(_scroller).position.pixels, closeTo(before, 1),
          reason: 'going back from a bill scrolled the list');
    }, () => _server(bills: 334));
  });

}
