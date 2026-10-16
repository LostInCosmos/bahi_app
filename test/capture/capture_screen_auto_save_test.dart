import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

/// DAS-79: a bill with zero validation issues and a verified supplier is now
/// saved by the server itself, with no tap on this phone — at the first
/// read, or later, once an admin correction or a vendor verification clears
/// the way while this phone was already sitting on it as pendingConfirm.
/// These pin the two places that learn about it: the very first status
/// fetch after a read finishes, and a later ask while the bill is still
/// being watched.
///
/// A retried bill joins this phone's own `_items` and is watched by the real
/// status loop (see capture_screen_retry_test.dart, which this borrows its
/// server/pump shape from) — unlike a card merely adopted from the shop's
/// list to show a dialog, which is never added to `_items` at all.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _result({List<Map<String, dynamic>> issues = const []}) => {
      'invoice': {
        'seller_name': 'ACME',
        'seller_gstin': '',
        'invoice_no': 'A-9',
        'invoice_date': '2026-08-01',
        'line_items': [
          {'product_name': 'Pan 40', 'qty': 2, 'rate': 50, 'gst_pct': 12, 'gross_amount': 100},
        ],
        'totals': {'subtotal': 100, 'total_cgst': 6, 'total_sgst': 6, 'grand_total': 112},
      },
      'extraction_meta': {'source_image': '8/5.jpg', 'method': 'llm'},
      'issues': issues,
    };

class _Server {
  _Server({this.saved = false});

  /// Ground truth the test flips directly — standing in for an admin
  /// correction or a vendor verification happening entirely server-side,
  /// independent of how many times anything on this phone has asked.
  bool saved;
  var statusAsks = 0;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          return _json({
            'jobs': [
              {'job_id': 5, 'status': 'failed', 'source_image': '8/5.jpg', 'created_at': '2026-10-08T10:00:00Z', 'issue_count': 0},
            ],
            'next_before_id': null,
          });
        }
        if (req.method == 'GET' && path == '/invoices/extract/5') {
          // Before any retry, the job is still failed: why it broke.
          if (statusAsks == 0) {
            return _json({
              'job_id': 5,
              'status': 'failed',
              'error': {'kind': 'attempts_exhausted', 'message': 'Qwen timed out reading this bill'},
            });
          }
          return _json({
            'job_id': 5,
            'status': 'done',
            'invoice_id': saved ? 55 : null,
            'review_state': 'none',
            'result': _result(),
          });
        }
        if (req.method == 'POST' && path == '/invoices/extract/5/retry') return _json({'job_id': 5});
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          statusAsks++;
          // The real server holds this request open for ~25s; answering at
          // once spins the watch loop without a pause (see
          // capture_screen_retry_test.dart's own note on this).
          await Future<void>.delayed(const Duration(seconds: 25));
          return _json({
            'jobs': [
              {'job_id': 5, 'status': 'done', 'saved': saved, 'attempt': 0, 'max_attempts': 3},
            ],
            'changed': true,
          });
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

Future<void> _open(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
  await _settle(tester);
}

Future<void> _retry(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('j:5')));
  await _settle(tester);
  await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
  await _settle(tester);
}

/// Advances past one held status request (~25s) and lets its follow-up
/// fetch and setState settle.
Future<void> _advanceOneRound(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 27));
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 40));
}

Finder get _savedIcon =>
    find.descendant(of: find.byType(BatchItemCard), matching: find.byIcon(Icons.check_rounded));
Finder get _pendingConfirmIcon =>
    find.descendant(of: find.byType(BatchItemCard), matching: find.byIcon(Icons.touch_app_rounded));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('clean and already verified by the time this phone first asks: lands Saved, no dialog ever shown',
      (tester) async {
    _ignoreOverflow();
    final server = _Server(saved: true);
    await http.runWithClient(() async {
      await _open(tester);
      await _retry(tester);
      await _advanceOneRound(tester);

      expect(find.text('Looks good — save'), findsNothing, reason: 'no tap for a clean, verified bill');
      expect(find.text('Save'), findsNothing);
      expect(_savedIcon, findsOneWidget, reason: 'the card shows Saved directly');
      expect(_pendingConfirmIcon, findsNothing, reason: 'never passes through Check & save');
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('clean but unverified: sits as Check & save, then is picked up live once the server saves it',
      (tester) async {
    _ignoreOverflow();
    final server = _Server(saved: false);
    await http.runWithClient(() async {
      await _open(tester);
      await _retry(tester);
      await _advanceOneRound(tester);

      // First ask: clean, but not yet saved — the unverified-supplier case
      // still waits on a human tap.
      expect(_pendingConfirmIcon, findsOneWidget, reason: 'pendingConfirm — nobody tapped it');
      expect(_savedIcon, findsNothing);
      // The status loop does not stop at one round just because this bill
      // reached a done-but-unsaved state — it immediately asked again
      // (DAS-79: unsaved is not settled), rather than dropping the job as
      // "terminal" the way a needsReview/pendingConfirm bill used to.
      expect(server.statusAsks, greaterThanOrEqualTo(2));

      // An admin correction or a vendor verification happens entirely
      // server-side — nothing on this phone does anything from here. That
      // ongoing watch is what lets the next round ever learn about it.
      server.saved = true;
      await _advanceOneRound(tester);

      expect(_savedIcon, findsOneWidget, reason: 'auto-saved live, with no tap on this phone');
      expect(_pendingConfirmIcon, findsNothing);
      await _finish(tester);
    }, () => server.client);
  });
}
