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
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

// DAS-180: a bill our team removes (discard, delete, or a merge into another
// bill) is left out of the status answer, which lists every job that still
// exists; opening it gives a 404. The phone's own card for it goes, with a
// note, instead of staying on screen for good.

const _key = 'bahi_batch_8';
final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _brief(int id, String status) =>
    {'job_id': id, 'status': status, 'saved': false, 'attempt': 1, 'max_attempts': 3};

/// Bills 5 and 6 are being read. With [fiveAbsent] the server no longer has
/// bill 5 at all; otherwise it reports 5 as done and then 404s its fetch.
class _Server {
  final bool fiveAbsent;
  _Server({required this.fiveAbsent});

  final requests = <String>[];
  var _answered = false;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        requests.add('${req.method} $path');
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') return _json({'jobs': [], 'next_before_id': null});
        if (req.method == 'GET' && path == '/invoices/extract/5') {
          return http.Response('{"detail":"not found"}', 404, headers: {'content-type': 'application/json'});
        }
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          if (_answered) await Future<void>.delayed(const Duration(seconds: 25));
          _answered = true;
          return _json({
            'jobs': [
              if (!fiveAbsent) _brief(5, 'done'),
              _brief(6, 'processing'),
            ],
            'changed': true,
          });
        }
        return http.Response('not found', 404);
      });
}

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('removed_bill_test'));
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
        {'label': 'Photo 2', 'sourceImages': ['8/6.jpg'], 'pages': [], 'status': 'processing', 'jobId': 6, 'lastJobId': 6},
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

  Future<List<String>> storedJobs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(prefs.getString(_key) ?? '[]') as List;
    return [for (final i in raw) '${(i as Map)['lastJobId']}'];
  }

  for (final absent in [true, false]) {
    final how = absent ? 'left out of the status answer' : 'gone when its result is fetched (404)';
    testWidgets('a bill $how loses its card, with a note; the other card stays', (tester) async {
      final server = _Server(fiveAbsent: absent);
      await http.runWithClient(() async {
        await start(tester);

        expect(find.byType(BatchItemCard), findsOneWidget, reason: 'only bill 6 is left');
        expect(find.text('Our team removed a bill.'), findsOneWidget);
        expect(await tester.runAsync(storedJobs), ['6'], reason: 'nor is it restored next time');
        expect(server.requests.where((r) => r.startsWith('POST /invoices/bulk-discard')), isEmpty,
            reason: 'nothing is sent: the server removed it already');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 30));
      }, () => server.client);
    });
  }
}
