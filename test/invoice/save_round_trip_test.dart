import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/presentation/review_screen.dart';

/// A save sends back what the server sent (AGENTS.md: "the review screen must
/// round-trip what the server sent").
///
/// Two ways it did not: the review form had no field for the supplier's
/// phone, so saving erased it; and after a revalidate it kept echoing the tax
/// rates it was opened with rather than the server's new ones. (The grid's
/// one-tap save once sent only a bill's first page; since DAS-71 it sends no
/// values at all — the server saves its own read, every page included — and
/// that is tested in capture_screen_save_job_test.dart.)

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _invoice({double cgstPct = 6, double sgstPct = 6, double netRate = 47.5, double totalGst = 12}) => {
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
          'net_rate': netRate,
        },
      ],
      // A bill that prints two discount lines, and its total GST (DAS-136).
      'totals': {
        'subtotal': 100,
        'total_discount': 3,
        'total_discount_2': 2,
        'total_cgst': 6,
        'total_sgst': 6,
        'total_gst': totalGst,
        'grand_total': 112,
      },
    };

class _Server {
  Map<String, dynamic>? saved;
  Map<String, dynamic>? revalidated;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path == '/invoices/revalidate') {
          revalidated = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'invoice': _invoice(cgstPct: 9, sgstPct: 9, netRate: 48, totalGst: 18), 'issues': []});
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

  // DAS-136: the drift test found the form dropped three fields the server
  // sends: a second printed discount, the printed total GST and each line's
  // net rate. The server's totals check adds total_discount_2 to
  // total_discount, so dropping it flagged a correct bill on revalidate.
  testWidgets('a revalidate and a save send back the second discount, total GST and net rate', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _openReview(tester);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);

      final asked = server.revalidated!;
      expect((asked['totals'] as Map)['total_discount_2'], 2);
      expect((asked['totals'] as Map)['total_gst'], 12);
      expect(((asked['line_items'] as List).single as Map)['net_rate'], 47.5);

      await _save(tester);
      final invoice = server.saved!['invoice'] as Map<String, dynamic>;
      expect((invoice['totals'] as Map)['total_discount_2'], 2);
      expect((invoice['totals'] as Map)['total_gst'], 18, reason: "the server's answer after the revalidate");
      expect(((invoice['line_items'] as List).single as Map)['net_rate'], 48);
    }, () => server.client);
  });
}
