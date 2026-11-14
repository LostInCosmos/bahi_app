import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/presentation/review_screen.dart';

/// DAS-185: a figure the read left blank stays blank. The phone used to turn
/// a blank subtotal, grand total, quantity, rate or amount into 0 the moment
/// it read the bill; opened and sent back untouched, that 0 was checked and
/// flagged, and shop 8's bill sat in "Processing" with nobody looking at it.

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _blankRead() => {
      'seller_name': 'M/S PREM DISTRIBUTORS',
      'seller_gstin': '09AAXPM1232H1ZG',
      'invoice_no': 'T017322',
      'invoice_date': '2026-11-05',
      'line_items': [
        {'product_name': 'Dolo 650', 'qty': null, 'rate': null, 'gst_pct': 12, 'gross_amount': null},
      ],
      'totals': {'subtotal': null, 'total_cgst': 19.5, 'total_sgst': 19.5, 'grand_total': null},
    };

const _blankIssues = [
  {'field': 'totals.subtotal', 'severity': 'error', 'message': 'Enter the subtotal.'},
  {'field': 'totals.grand_total', 'severity': 'error', 'message': 'Enter the grand total.'},
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the model keeps a blank figure null, both ways', () {
    final inv = InvoiceData.fromJson(_blankRead());
    expect(inv.totals.subtotal, isNull);
    expect(inv.totals.grandTotal, isNull);
    expect(inv.lineItems.single.qty, isNull);
    expect(inv.lineItems.single.rate, isNull);
    expect(inv.lineItems.single.grossAmount, isNull);
    final back = inv.toJson();
    expect((back['totals'] as Map)['subtotal'], isNull);
    expect((back['totals'] as Map)['grand_total'], isNull);
    final line = (back['line_items'] as List).single as Map;
    expect([line['qty'], line['rate'], line['gross_amount']], [null, null, null]);
    expect((back['totals'] as Map)['total_cgst'], 19.5, reason: 'a figure that was read is kept');
    final noDate = InvoiceData.fromJson({..._blankRead(), 'invoice_date': null});
    expect(noDate.toJson()['invoice_date'], isNull, reason: 'the server refuses "" for a blank date');
  });

  testWidgets('opened and revalidated untouched, a blank goes back blank, not 0, and shows as a field to fill',
      (tester) async {
    final puts = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      if (req.method == 'PUT' && req.url.path == '/invoices/extract/7/draft') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        puts.add(body);
        return _json({'invoice': body['invoice'], 'issues': _blankIssues, 'draft_rev': 1, 'saved': false});
      }
      return http.Response('not found', 404);
    });
    final read = ExtractionResult.fromJson({
      'invoice': _blankRead(),
      'extraction_meta': {'source_image': '8/7.jpg', 'method': 'llm'},
      'issues': _blankIssues,
    });
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(800, 4000));
      await tester.pumpWidget(MaterialApp(home: ReviewScreen(result: read, jobId: 7)));
      await tester.pump();

      String text(String label) => tester.widget<TextField>(find.widgetWithText(TextField, label)).controller!.text;
      expect(text('Subtotal'), '', reason: 'blank, not "0"');
      expect(text('Grand total'), '');
      expect(find.text('Enter the subtotal.'), findsOneWidget, reason: 'marked as a field to fill');

      await tester.tap(find.text('Revalidate'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final sent = puts.single['invoice'] as Map<String, dynamic>;
      expect((sent['totals'] as Map)['subtotal'], isNull);
      expect((sent['totals'] as Map)['grand_total'], isNull);
      final line = (sent['line_items'] as List).single as Map;
      expect([line['qty'], line['rate'], line['gross_amount']], [null, null, null]);
      expect((sent['totals'] as Map)['total_cgst'], 19.5);
      expect(text('Subtotal'), '', reason: "still blank after the server's answer");
    }, () => client);
  });
}
