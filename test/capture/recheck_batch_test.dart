import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

/// DAS-105: reopening the tab re-checks every held unsaved card with ONE
/// status request (`wait: false`) whose briefs carry `flag_count`; only a
/// bill whose flags were cleared costs a result fetch. Before, each card
/// fetched its full result on every reopen.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

String _tokenFor(int tenantId) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'tenant_id': tenantId})}.sig';
}

Map<String, dynamic> _result({required bool flagged}) => {
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
      'extraction_meta': {'source_image': '1/99.jpg', 'method': 'llm'},
      'issues': [
        if (flagged) {'field': 'invoice_date', 'message': 'unreadable', 'severity': 'error'},
      ],
    };

void main() {
  testWidgets('tab reopen: one wait:false status request for the held cards; a cleared bill is fetched once',
      (tester) async {
    // A restored finished card is handed over to the server's list at
    // start-up (DAS-62), so the card is restored IN FLIGHT and read this
    // session: the first held status request answers "done" at once.
    final card = BatchItem(label: 'Bill', pages: [])
      ..sourceImages = ['1/99.jpg']
      ..status = BatchItemStatus.processing
      ..jobId = 99
      ..lastJobId = 99;
    SharedPreferences.setMockInitialValues({
      'bahi_batch_1': jsonEncode([card.toJson()]),
    });
    ApiClient.instance.token = _tokenFor(1);
    addTearDown(() => ApiClient.instance.token = null);
    final dir = Directory.systemTemp.createTempSync('recheck_batch_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    var readOnce = false;
    var cleared = false; // our team fixes the last flag, server-side
    var resultFetches = 0;
    final quickStatusAsks = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path == '/folders') return _json([]);
      if (path == '/invoices/extract') {
        // Not on the shop's list (a discarded retry copy): the phone keeps its card.
        return _json({'jobs': [], 'next_before_id': null, 'counts': {'root': {}}});
      }
      if (req.method == 'POST' && path == '/invoices/extract/status') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['wait'] == true) {
          if (!readOnce) {
            readOnce = true; // the read finishes, flagged
            return _json({
              'jobs': [
                {'job_id': 99, 'status': 'done', 'saved': false, 'attempt': 1, 'max_attempts': 3},
              ],
              'changed': true,
            });
          }
          await Future<void>.delayed(const Duration(seconds: 25));
          return _json({'jobs': [], 'changed': false});
        }
        quickStatusAsks.add(body);
        return _json({
          'jobs': [
            {'job_id': 99, 'status': 'done', 'saved': false, 'review_state': cleared ? 'done' : 'pending',
             'flag_count': cleared ? 0 : 1, 'attempt': 1, 'max_attempts': 3},
          ],
          'changed': true,
        });
      }
      if (path == '/invoices/extract/99') {
        resultFetches++;
        return _json({'job_id': 99, 'status': 'done', 'invoice_id': null, 'review_state': cleared ? 'done' : 'pending',
            'result': _result(flagged: !cleared)});
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      final key = GlobalKey<CaptureScreenState>();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(key: key, onBatchFinished: () {}))));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(BatchItemCard), findsOneWidget);
      expect(find.descendant(of: find.byType(BatchItemCard), matching: find.byIcon(Icons.touch_app_rounded)),
          findsNothing, reason: 'flagged: Needs review, not Not saved');
      final fetchesAfterBuild = resultFetches; // the first-done fetch and the card's own one-time check

      // Reopen the tab: still flagged, so nothing beyond the one status request.
      await key.currentState!.refresh();
      await tester.pump(const Duration(milliseconds: 100));
      expect(quickStatusAsks.length, 1);
      expect(quickStatusAsks.single['job_ids'], [99]);
      expect(quickStatusAsks.single['wait'], false);
      expect(resultFetches, fetchesAfterBuild, reason: 'flag_count 1: no result fetch');

      // Our team clears the flag; the next reopen fetches the result once.
      cleared = true;
      await key.currentState!.refresh();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(quickStatusAsks.length, 2);
      expect(resultFetches, fetchesAfterBuild + 1);
      expect(find.descendant(of: find.byType(BatchItemCard), matching: find.byIcon(Icons.touch_app_rounded)),
          findsOneWidget, reason: 'now Not saved (pendingConfirm)');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => client);
  });
}
