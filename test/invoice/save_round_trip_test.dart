import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/presentation/review_screen.dart';

/// A save sends back what the server sent (AGENTS.md: "the review screen must
/// round-trip what the server sent").
///
/// Three ways it did not: the review form had no field for the supplier's
/// phone, so saving erased it; after a revalidate it kept echoing the tax
/// rates it was opened with rather than the server's new ones; and the grid's
/// one-tap save of a bill opened from the shop's list sent only its first
/// page, because this phone knows only that page of it.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _invoice({double cgstPct = 6, double sgstPct = 6}) => {
      'seller_name': 'ACME',
      'seller_gstin': '09AAGCP8428E1Z7',
      'seller_phone': '9876543210',
      'invoice_no': 'A-9',
      'invoice_date': '2026-08-01',
      'line_items': [
        {
          'product_name': 'Pan 40',
          'qty': 2,
          'rate': 50,
          'gst_pct': 12,
          'cgst_pct': cgstPct,
          'sgst_pct': sgstPct,
          'gross_amount': 100,
        },
      ],
      'totals': {'subtotal': 100, 'total_cgst': 6, 'total_sgst': 6, 'grand_total': 112},
    };

class _Server {
  Map<String, dynamic>? saved;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path == '/invoices/vendor-lookup') {
          return _json({'needs_confirmation': false, 'vendor_known': true, 'verified': true});
        }
        if (req.method == 'POST' && path == '/invoices/revalidate') {
          return _json({'invoice': _invoice(cgstPct: 9, sgstPct: 9), 'issues': []});
        }
        if (req.method == 'POST' && path == '/invoices') {
          saved = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'invoice_id': 5});
        }
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          return _json({
            'jobs': [
              {'job_id': 9, 'status': 'done', 'source_image': '8/9.jpg', 'created_at': '2026-10-08T12:00:00Z', 'issue_count': 0},
            ],
            'next_before_id': null,
          });
        }
        if (req.method == 'GET' && path == '/invoices/extract/9') {
          return _json({
            'job_id': 9,
            'status': 'done',
            'result': {
              'invoice': _invoice(),
              'extraction_meta': {
                'source_image': '8/9.jpg',
                'extra_source_images': ['8/9b.jpg', '8/9c.jpg'],
                'method': 'llm',
                'vendor_known': true,
              },
              'issues': [],
            },
          });
        }
        if (req.method == 'POST' && path == '/invoices/extract/status') {
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

Future<void> _openReview(WidgetTester tester) async {
  final result = ExtractionResult.fromJson({
    'invoice': _invoice(),
    'extraction_meta': {'source_image': '8/9.jpg', 'method': 'llm', 'vendor_known': true},
    'issues': [],
  });
  // Tall enough that the whole form, Save included, is built.
  await tester.binding.setSurfaceSize(const Size(800, 4000));
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReviewScreen(result: result))),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save invoice'));
  await _settle(tester);
  await tester.pump(const Duration(seconds: 1)); // the saved tick
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets("the review screen saves the supplier's phone it was never shown", (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _openReview(tester);
      await _save(tester);

      final invoice = server.saved!['invoice'] as Map<String, dynamic>;
      expect(invoice['seller_phone'], '9876543210');
      expect((server.saved!['extraction_meta'] as Map)['vendor_known'], isTrue);
      expect((server.saved!['extraction_meta'] as Map)['reviewed_by_user'], isTrue);
    }, () => server.client);
  });

  testWidgets("after a revalidate it saves the server's tax rates, not the ones it opened with", (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _openReview(tester);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      await _save(tester);

      final line = ((server.saved!['invoice'] as Map)['line_items'] as List).single as Map;
      expect(line['cgst_pct'], 9);
      expect(line['sgst_pct'], 9);
    }, () => server.client);
  });

  testWidgets("a multi-page bill from the shop's list is saved with every page", (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    final server = _Server();
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('j:9')));
      await _settle(tester);
      await tester.tap(find.text('Looks good — save'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1)); // the saved tick
      await _settle(tester);

      final meta = server.saved!['extraction_meta'] as Map;
      expect(meta['source_image'], '8/9.jpg');
      expect(meta['extra_source_images'], ['8/9b.jpg', '8/9c.jpg']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 40));
    }, () => server.client);
  });
}
