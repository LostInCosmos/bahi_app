import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/utils/app_foreground.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

// DAS-132: the status request carries `seen`, what each card draws, and the
// server answers at once when a bill differs from it instead of holding the
// request 25 s. The fake server here compares as the backend's
// status_seen.differs does: any job whose card_state is not in `seen`, or
// differs, answers at once; otherwise the request is held.

const _key = 'bahi_batch_8';
final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _cleanJob() => {
      'job_id': 5,
      'status': 'done',
      'invoice_id': null,
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
    };

/// A server whose bill 5 finished (clean, its own save not done) before the
/// phone's first request.
class _Server {
  final bool resultFails;
  _Server({this.resultFails = false});

  final seenSent = <Map<String, dynamic>?>[];
  final answeredAfter = <Duration>[];
  final _clock = Stopwatch()..start();

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') return _json({'jobs': [], 'next_before_id': null});
        if (req.method == 'GET' && path == '/invoices/extract/5') {
          return resultFails ? http.Response('boom', 500) : _json(_cleanJob());
        }
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          final seen = (jsonDecode(req.body) as Map<String, dynamic>)['seen'] as Map<String, dynamic>?;
          seenSent.add(seen);
          const state = 'done:unsaved:0';
          final start = _clock.elapsed;
          if (seen?['5'] == state) await Future<void>.delayed(const Duration(seconds: 25));
          answeredAfter.add(_clock.elapsed - start);
          return _json({
            'jobs': [
              {'job_id': 5, 'status': 'done', 'saved': false, 'attempt': 1, 'max_attempts': 3, 'review_state': 'none', 'flag_count': 0},
            ],
            'changed': seen?['5'] != state,
          });
        }
        return http.Response('not found', 404);
      });
}

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('capture_seen_test'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    AppForeground.reset();
    ApiClient.instance.token = _token;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    SharedPreferences.setMockInitialValues({
      _key: jsonEncode([
        {'label': 'Photo 1', 'sourceImages': ['8/5.jpg'], 'pages': [], 'status': 'processing', 'jobId': 5, 'lastJobId': 5},
      ]),
    });
  });
  tearDown(() {
    AppForeground.reset();
    ApiClient.instance.token = null;
  });

  Future<void> start(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a bill that finished before the request is answered at once, then the next request waits', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester);

      expect(server.seenSent.first, {'5': 'queued'}, reason: 'the restored card is being read');
      expect(server.answeredAfter.first, lessThan(const Duration(seconds: 1)),
          reason: 'the bill differs from the card, so it is not held for 25 s');
      expect(server.seenSent.last, {'5': 'done:unsaved:0'}, reason: 'the card now draws a finished, unsaved bill');

      final asked = server.seenSent.length;
      await tester.pump(const Duration(seconds: 10));
      expect(server.seenSent.length, asked, reason: 'nothing differs: the server holds the request');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }, () => server.client);
  });

  testWidgets('a finished bill whose result cannot be fetched is asked about every 2 s, not in a tight loop', (tester) async {
    final server = _Server(resultFails: true);
    await http.runWithClient(() async {
      await start(tester);
      final before = server.seenSent.length;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      final asks = server.seenSent.length - before;
      expect(asks, inInclusiveRange(8, 11), reason: 'one request per 2 s pause over 20 s, got $asks');
      expect(server.seenSent.last, {'5': 'queued'}, reason: 'the card still shows it being read');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }, () => server.client);
  });
}
