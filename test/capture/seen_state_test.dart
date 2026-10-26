import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/seen_state.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/models/job_status.dart';

// DAS-132: the strings the phone sends in `seen`, and the server's own answer
// as the same string. They must agree exactly with the backend's
// status_seen.card_state, or every request answers at once.

BatchItem _card(BatchItemStatus status) => BatchItem(label: 'Photo 1', pages: [])..status = status;

ExtractionResult _result(List<String> issueFields) => ExtractionResult.fromJson({
      'invoice': {
        'seller_name': 'ACME',
        'invoice_no': 'A-9',
        'invoice_date': '2026-08-01',
        'line_items': [],
        'totals': {'grand_total': 112},
      },
      'extraction_meta': {'source_image': '8/5.jpg', 'method': 'llm'},
      'issues': [
        for (final f in issueFields) {'field': f, 'severity': 'error', 'message': 'check $f'},
      ],
    });

void main() {
  test("a brief's cardState is the backend's card_state", () {
    JobStatusBrief b(String status, {int attempt = 1, bool saved = false, int? flags}) =>
        JobStatusBrief(jobId: 1, status: status, attempt: attempt, maxAttempts: 3, saved: saved, flagCount: flags);
    expect(b('queued').cardState, 'queued');
    expect(b('processing').cardState, 'processing');
    expect(b('retrying', attempt: 2).cardState, 'retrying:2');
    expect(b('done', saved: true, flags: 3).cardState, 'done:saved');
    expect(b('done', flags: 3).cardState, 'done:unsaved:3');
    expect(b('done').cardState, 'done:unsaved:0', reason: 'an older server sends no count: card_state uses 0');
    expect(b('failed').cardState, 'failed');
    expect(b('cancelled').cardState, 'cancelled');
  });

  test('a card being read says queued, processing or retrying with its attempt', () {
    final card = _card(BatchItemStatus.processing);
    expect(cardSeenState(card), 'queued', reason: 'not yet seen picked up (also every card after a restart)');
    card.processingSince = DateTime.utc(2026, 10, 27);
    expect(cardSeenState(card), 'processing');
    card
      ..retryAttempt = 2
      ..retryAt = DateTime.utc(2026, 10, 27, 1);
    expect(cardSeenState(card), 'retrying:2');
  });

  test('a card being read ignores a "done" the phone could not act on', () {
    final card = _card(BatchItemStatus.processing)..processingSince = DateTime.utc(2026, 10, 27);
    expect(cardSeenState(card, lastAnswer: 'done:unsaved:0'), 'processing',
        reason: 'the result fetch failed: the server must answer at once so the phone tries again');
  });

  test('a finished unsaved bill sends the count it was told, else counts its own flags', () {
    expect(cardSeenState(_card(BatchItemStatus.pendingConfirm)), 'done:unsaved:0');
    final flagged = _card(BatchItemStatus.needsReview)..result = _result(['invoice_no', 'seller_gstin', 'grand_total']);
    expect(cardSeenState(flagged), 'done:unsaved:2', reason: 'the GSTIN is not counted, as on the server');
    expect(cardSeenState(flagged, lastAnswer: 'done:unsaved:1'), 'done:unsaved:1',
        reason: 'the card does not redraw for 2 → 1, so the phone says it has seen 1');
    expect(cardSeenState(flagged, lastAnswer: 'done:saved'), 'done:unsaved:2',
        reason: 'saved but the card has not caught up: still different, so asked again');
  });

  test('cards the loop does not watch have no state', () {
    for (final s in [BatchItemStatus.needsCrop, BatchItemStatus.preparing, BatchItemStatus.ready, BatchItemStatus.saved, BatchItemStatus.failed]) {
      expect(cardSeenState(_card(s)), isNull, reason: '$s');
    }
  });
}
