import 'dart:async';
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

  /// The next PUT checks clean and the bill saves itself (DAS-180), unless
  /// [stayUnsaved]: the shop unsaved it, so it waits for the shop's Save.
  bool clean = false;
  bool stayUnsaved = false;

  /// The bill was removed: every route answers bill_removed (DAS-193).
  bool removed = false;

  /// The Save is a duplicate of a saved bill (DAS-193).
  bool duplicate = false;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (removed && path.startsWith('/invoices')) {
          return _json({'detail': 'This bill was removed.', 'error': 'bill_removed'}, status: 404);
        }
        if (duplicate && req.method == 'POST' && path == '/invoices') {
          return _json({
            'detail': 'Bill T-EDITED of 01 Oct 2026 is already saved.',
            'error': 'duplicate_bill',
            'existing_invoice_id': 696,
          }, status: 409);
        }
        if (req.method == 'PUT' && path == '/invoices/extract/7/draft') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          puts.add(body);
          if (conflict) {
            conflict = false;
            return _json({'detail': 'newer draft', 'field': 'draft_rev', 'current_rev': 5}, status: 409);
          }
          rev++;
          if (clean) {
            final saves = !stayUnsaved;
            return _json({'invoice': body['invoice'], 'issues': [], 'draft_rev': rev, 'stale': false,
                'saved': saves, 'invoice_id': saves ? 71 : null});
          }
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

/// What the form returned when it closed: the saved bill's id, or null.
int? _popped;

/// How often the form said our team removed the bill.
var _removedCalls = 0;

Future<void> _open(WidgetTester tester,
    {BillDraft? draft,
    void Function(int)? onSent,
    bool unsavedByShop = false,
    void Function(String, int?)? onDuplicate}) async {
  _popped = null;
  _removedCalls = 0;
  await tester.binding.setSurfaceSize(const Size(800, 4000));
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => _popped = await Navigator.of(context).push<int>(MaterialPageRoute(
            builder: (_) => ReviewScreen(
                result: _read(),
                jobId: 7,
                draft: draft,
                onDraftSent: onSent,
                unsavedByShop: unsavedByShop,
                onRemoved: () => _removedCalls++,
                onDuplicate: onDuplicate))),
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

  testWidgets('a stale draft: a second tap on Use their version while the first is being sent does nothing', (tester) async {
    final server = _Server();
    final held = Completer<http.Response>();
    var deletes = 0;
    // The delete is held open, so the second tap lands while the first is in flight.
    final slow = MockClient((req) {
      if (req.method == 'DELETE') {
        deletes++;
        return held.future;
      }
      return server.client.send(req).then(http.Response.fromStream);
    });
    final stale = BillDraft(invoice: InvoiceData.fromJson(_invoice('T-MINE')), issues: const [], rev: 2, stale: true);
    await http.runWithClient(() async {
      await _open(tester, draft: stale);
      await tester.tap(find.text('Use their version'));
      await tester.pump();
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Use their version')).onPressed, isNull);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Keep my corrections')).onPressed, isNull);
      await tester.tap(find.text('Use their version'), warnIfMissed: false);
      await tester.pump();
      expect(deletes, 1);
      held.complete(http.Response('{}', 200, headers: {'content-type': 'application/json'}));
      await _settle(tester);
      expect(find.textContaining('Our team updated this bill'), findsNothing);
      expect(deletes, 1);
    }, () => slow);
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

  testWidgets('a bill the shop unsaved: its Save sends the corrections and names the read it corrects', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester,
          unsavedByShop: true,
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

  // DAS-180: a bill from a photo saves itself once it checks clean. The form
  // has no Save and no "save anyway"; Revalidate is what saves it.
  testWidgets('a flagged bill offers Revalidate only: no Save, no "save anyway"', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text('Revalidate'), findsOneWidget);
      expect(find.text('Save invoice'), findsNothing);
      expect(find.textContaining('save anyway'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
    }, () => server.client);
  });

  testWidgets('Revalidate that checks clean saves the bill, and the form closes with its id', (tester) async {
    final server = _Server()..clean = true;
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1)); // the saved tick
      await _settle(tester);
      expect(find.text('Revalidate'), findsNothing, reason: 'the form closed');
      expect(_popped, 71);
      expect(server.saved, isNull, reason: 'no separate save request');
    }, () => server.client);
  });

  testWidgets('Revalidate that is still flagged keeps the form open, with no Save', (tester) async {
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      expect(find.textContaining('our team will check it'), findsOneWidget);
      expect(find.text('Save invoice'), findsNothing);
      expect(_popped, isNull);
    }, () => server.client);
  });

  testWidgets('a bill the shop unsaved does not save itself on a clean Revalidate; its Save does', (tester) async {
    final server = _Server()
      ..clean = true
      ..stayUnsaved = true;
    await http.runWithClient(() async {
      await _open(tester, unsavedByShop: true);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      expect(find.text('Revalidate'), findsOneWidget, reason: 'still open: it waits for the Save');
      await tester.tap(find.text('Save invoice'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(server.saved, isNotNull);
      expect(_popped, 70);
    }, () => server.client);
  });

  // DAS-193: a bill our team removed, or a duplicate, while the form was open.
  testWidgets('Revalidate on a bill our team removed closes the form and says so to the caller', (tester) async {
    final server = _Server()..removed = true;
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('Revalidate'));
      await _settle(tester);
      expect(find.text('Revalidate'), findsNothing, reason: 'the form closed');
      expect(_removedCalls, 1);
      expect(find.textContaining('Could not revalidate'), findsNothing);
    }, () => server.client);
  });

  testWidgets("Save on a bill our team removed closes the form too", (tester) async {
    final server = _Server()..removed = true;
    await http.runWithClient(() async {
      await _open(tester,
          unsavedByShop: true,
          draft: BillDraft(invoice: InvoiceData.fromJson(_invoice('T-EDITED', grandTotal: 210)), issues: const [], rev: 3));
      await tester.tap(find.text('Save invoice'));
      await _settle(tester);
      expect(find.text('Save invoice'), findsNothing);
      expect(_removedCalls, 1);
    }, () => server.client);
  });

  testWidgets("a duplicate Save shows the server's sentence, not \"Save failed\"", (tester) async {
    final server = _Server()..duplicate = true;
    await http.runWithClient(() async {
      await _open(tester,
          unsavedByShop: true,
          draft: BillDraft(invoice: InvoiceData.fromJson(_invoice('T-EDITED', grandTotal: 210)), issues: const [], rev: 3));
      await tester.tap(find.text('Save invoice'));
      await _settle(tester);
      expect(find.text('Bill T-EDITED of 01 Oct 2026 is already saved.'), findsOneWidget);
      expect(find.textContaining('Save failed'), findsNothing);
      expect(_popped, isNull, reason: 'the form stays');
    }, () => server.client);
  });

  testWidgets('with a caller for duplicates, the form closes and hands over the sentence and the saved bill', (tester) async {
    final server = _Server()..duplicate = true;
    final got = <Object?>[];
    await http.runWithClient(() async {
      await _open(tester,
          unsavedByShop: true,
          onDuplicate: (message, id) => got.addAll([message, id]),
          draft: BillDraft(invoice: InvoiceData.fromJson(_invoice('T-EDITED', grandTotal: 210)), issues: const [], rev: 3));
      await tester.enterText(_field('Invoice number'), 'T-TYPED');
      await tester.tap(find.text('Save invoice'));
      await _settle(tester);
      expect(find.text('Save invoice'), findsNothing, reason: 'the form closed');
      expect(got, ['Bill T-EDITED of 01 Oct 2026 is already saved.', 696]);
      expect(server.puts, isNotEmpty, reason: 'the corrections typed go into the draft on the way out');
      expect((server.puts.last['invoice'] as Map)['invoice_no'], 'T-TYPED');
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
