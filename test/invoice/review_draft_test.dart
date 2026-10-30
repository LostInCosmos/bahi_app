import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/hand_over.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/presentation/review_screen.dart';

/// The shop's corrections to a read bill are kept on the server (DAS-153).
///
/// They lived only in the phone's card, which handed over to the shop's list
/// once the bill was read (DAS-62) — and the list shows the read. Opening the
/// bill again showed the original values, and another phone never saw them.

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _invoice(String no, {double grandTotal = 450}) => {
      'seller_name': 'ACME PHARMA (TEST)',
      'seller_gstin': '09AAGCP8428E1Z7',
      'invoice_no': no,
      'invoice_date': '2026-10-01',
      'line_items': [
        {'product_name': 'TEST MEDICINE TAB', 'qty': 10, 'rate': 20, 'gst_pct': 5, 'cgst_pct': 2.5, 'sgst_pct': 2.5, 'gross_amount': 210},
      ],
      'totals': {'subtotal': 200, 'total_cgst': 5, 'total_sgst': 5, 'grand_total': grandTotal},
    };

const _flag = {'field': 'totals.grand_total', 'message': 'Grand total does not add up', 'severity': 'error'};

ExtractionResult _read() => ExtractionResult.fromJson({
      'invoice': _invoice('T-1'),
      'extraction_meta': {'source_image': '1/7.jpg', 'method': 'llm'},
      'issues': [_flag],
    });

class _Server {
  final puts = <Map<String, dynamic>>[];
  final deletes = <String>[];
  Map<String, dynamic>? saved;
  int rev = 0;

  /// Answer the next PUT with a 409: another phone wrote revision 5.
  bool conflict = false;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'PUT' && path == '/invoices/extract/7/draft') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          puts.add(body);
          if (conflict) {
            conflict = false;
            return _json({'detail': 'newer draft', 'field': 'draft_rev', 'current_rev': 5}, status: 409);
          }
          rev++;
          return _json({'invoice': body['invoice'], 'issues': [_flag], 'draft_rev': rev, 'stale': false});
        }
        if (req.method == 'DELETE' && path == '/invoices/extract/7/draft') {
          deletes.add(path);
          return http.Response('', 204);
        }
        if (req.method == 'GET' && path == '/invoices/extract/7') {
          return _json({
            'job_id': 7,
            'status': 'done',
            'result': {
              'invoice': _invoice('T-1'),
              'extraction_meta': {'source_image': '1/7.jpg', 'method': 'llm'},
              'issues': [_flag],
            },
            'draft': {'invoice': _invoice('FROM-OTHER-PHONE'), 'issues': [_flag], 'draft_rev': 5, 'stale': false},
          });
        }
        if (req.method == 'POST' && path == '/invoices') {
          saved = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'invoice_id': 70});
        }
        return http.Response('not found', 404);
      });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, {BillDraft? draft, void Function(int)? onSent}) async {
  await tester.binding.setSurfaceSize(const Size(800, 4000));
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ReviewScreen(result: _read(), jobId: 7, draft: draft, onDraftSent: onSent))),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Finder _field(String label) => find.widgetWithText(TextField, label);

String _text(WidgetTester tester, String label) => tester.widget<TextField>(_field(label)).controller!.text;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Revalidate keeps the corrections on the server, as a draft of the read', (tester) async {
    final server = _Server();
    final sent = <int>[];
    await http.runWithClient(() async {
      await _open(tester, onSent: sent.add);
      await tester.enterText(_field('Invoice number'), 'T-EDITED');
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);

      expect(server.puts, hasLength(1));
      expect((server.puts.single['invoice'] as Map)['invoice_no'], 'T-EDITED');
      expect(server.puts.single['base_rev'], isNull, reason: 'no draft yet');
      expect(sent, [1]);

      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      expect(server.puts.last['base_rev'], 1, reason: 'each write builds on the last');
    }, () => server.client);
  });

  testWidgets('it opens on the draft, not the read', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester,
          draft: BillDraft(invoice: InvoiceData.fromJson(_invoice('T-EDITED')), issues: const [], rev: 3));
      expect(_text(tester, 'Invoice number'), 'T-EDITED');
    }, () => server.client);
  });

  testWidgets('leaving with unsent changes sends them; leaving with none sends nothing', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.pageBack();
      await _settle(tester);
      expect(server.puts, isEmpty);

      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.enterText(_field('Invoice number'), 'T-TYPED');
      await tester.pageBack();
      await _settle(tester);
      expect(server.puts, hasLength(1));
      expect((server.puts.single['invoice'] as Map)['invoice_no'], 'T-TYPED');
    }, () => server.client);
  });

  testWidgets("another phone's newer draft is shown, and said so", (tester) async {
    final server = _Server()..conflict = true;
    await http.runWithClient(() async {
      await _open(tester);
      await tester.enterText(_field('Invoice number'), 'T-MINE');
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);

      expect(_text(tester, 'Invoice number'), 'FROM-OTHER-PHONE');
      expect(find.textContaining('corrected on another phone'), findsOneWidget);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      expect(server.puts.last['base_rev'], 5, reason: 'now building on the other phone\'s revision');
    }, () => server.client);
  });

  testWidgets("a stale draft: Use their version drops it; Keep my corrections writes it with rebase", (tester) async {
    final server = _Server();
    final stale = BillDraft(invoice: InvoiceData.fromJson(_invoice('T-MINE')), issues: const [], rev: 2, stale: true);
    await http.runWithClient(() async {
      await _open(tester, draft: stale);
      expect(find.textContaining('Our team updated this bill'), findsOneWidget);
      await tester.tap(find.text('Use their version'));
      await _settle(tester);
      expect(server.deletes, hasLength(1));
      expect(_text(tester, 'Invoice number'), 'T-1', reason: "the team's read");
      expect(find.textContaining('Our team updated this bill'), findsNothing);

      await tester.pageBack();
      await _settle(tester);
      await _open(tester, draft: stale);
      await tester.tap(find.text('Keep my corrections'));
      await _settle(tester);
      expect(server.puts.last['rebase'], isTrue);
      expect(server.puts.last['base_rev'], 2);
      expect(_text(tester, 'Invoice number'), 'T-MINE');
    }, () => server.client);
  });

  testWidgets('the save sends the corrections and names the read it corrects', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester,
          draft: BillDraft(invoice: InvoiceData.fromJson(_invoice('T-EDITED', grandTotal: 210)), issues: const [], rev: 3));
      await tester.tap(find.text('Save invoice'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1)); // the saved tick
      await _settle(tester);
      expect((server.saved!['extraction_meta'] as Map)['job_id'], 7);
      expect((server.saved!['invoice'] as Map)['invoice_no'], 'T-EDITED');
      expect(server.puts, isEmpty, reason: 'saved: nothing left to send on the way out');
    }, () => server.client);
  });

  test('a card with corrections the server has not got never hands over', () {
    final card = BatchItem(label: 'Bill', pages: [])
      ..sourceImages = ['1/7.jpg']
      ..status = BatchItemStatus.needsReview
      ..lastJobId = 7
      ..correctionUnsent = true;
    final row = UploadSummary(
        jobId: 7, status: 'done', sourceImage: '1/7.jpg', createdAt: DateTime(2026, 10, 30), issueCount: 1);
    final split = splitHandOver([card], [row]);
    expect(split.handed, isEmpty);
    expect(split.refile, isEmpty);
    card.correctionUnsent = false;
    expect(splitHandOver([card], [row]).handed, [card], reason: 'once sent, the server holds them');
  });

  test('a card keeps its correction state across a restart', () {
    final card = BatchItem(label: 'Bill', pages: [])
      ..sourceImages = ['1/7.jpg']
      ..status = BatchItemStatus.needsReview
      ..lastJobId = 7
      ..correctionRev = 4
      ..correctionUnsent = true;
    final back = BatchItem.fromJson(jsonDecode(jsonEncode(card.toJson())) as Map<String, dynamic>)!;
    expect(back.correctionRev, 4);
    expect(back.correctionUnsent, isTrue);
  });
}
