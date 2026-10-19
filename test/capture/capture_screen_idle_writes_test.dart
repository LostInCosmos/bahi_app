// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

// DAS-92: a bill left "Not saved" is watched until it is saved (DAS-79), and
// every ~25 s the server answers that nothing moved. The whole batch used to
// be rewritten each of those rounds — 1.61 MiB for a 300-bill batch, measured
// in DAS-86. This drives the real screen and the real status loop against a
// server that holds each status request 25 s, as the real one does, and counts
// the rounds that wrote the stored batch.
//
// Counting: before each round the stored batch is replaced with a marker. A
// round that writes replaces the marker; a round that does not leaves it.
// Server and pump shape from capture_screen_auto_save_test.dart.

const _key = 'bahi_batch_8';
const _marker = 'not written this round';
final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

class _Server {
  bool saved = false;
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
          if (statusAsks == 0) {
            return _json({'job_id': 5, 'status': 'failed', 'error': {'kind': 'attempts_exhausted', 'message': 'timed out'}});
          }
          return _json({
            'job_id': 5,
            'status': 'done',
            'invoice_id': saved ? 55 : null,
            'review_state': 'none',
            'result': {
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
              'issues': [],
            },
          });
        }
        if (req.method == 'POST' && path == '/invoices/extract/5/retry') return _json({'job_id': 5});
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          statusAsks++;
          await Future<void>.delayed(const Duration(seconds: 25));
          return _json({
            'jobs': [
              {'job_id': 5, 'status': 'done', 'saved': saved, 'attempt': 0, 'max_attempts': 3},
            ],
            'changed': !saved ? false : true,
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

/// One held status request (~25 s) and its follow-up; true if it wrote.
Future<bool> _roundWrote(WidgetTester tester, SharedPreferences prefs) async {
  await prefs.setString(_key, _marker);
  await tester.pump(const Duration(seconds: 27));
  await _settle(tester);
  return prefs.getString(_key) != _marker;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = _token; // so the screen has a store to write to
  });
  tearDown(() => ApiClient.instance.token = null);

  testWidgets('an hour of idle rounds writes nothing; the round that saves the bill writes it', (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    final server = _Server();
    late int idleWrites;
    late bool savingRoundWrote;
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);
      final prefs = await SharedPreferences.getInstance();

      // Retry the shop's failed bill: it joins this phone's batch, is read,
      // and lands Not saved — watched from then on.
      await tester.tap(find.byKey(const ValueKey('j:5')));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await _settle(tester);
      expect(await _roundWrote(tester, prefs), isTrue, reason: 'the bill moving to Not saved is a change, and is stored');

      // An hour of the server holding 25 s and answering that nothing moved.
      idleWrites = 0;
      for (var round = 0; round < 144; round++) {
        if (await _roundWrote(tester, prefs)) idleWrites++;
      }

      server.saved = true; // saved server-side, nothing done on this phone
      savingRoundWrote = await _roundWrote(tester, prefs);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);

    print('MEASURED idle rounds that rewrote the batch: $idleWrites of 144 (one hour of 25 s holds)');
    expect(idleWrites, 0, reason: 'nothing stored changed in any of them');
    expect(savingRoundWrote, isTrue, reason: 'a real change is still stored, so a restart restores it');
  });
}
