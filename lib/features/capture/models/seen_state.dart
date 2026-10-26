/// What a capture card is drawing for its bill, as the string the server
/// compares in the status request's `seen` map (DAS-132). The server answers
/// at once when any bill's string differs from its own, and waits only when
/// every one matches, so a bill that finished a moment before the request
/// is reported without waiting out the 25 s hold.
library;

import 'batch_item.dart';

/// The card's state, or null for a card the status loop does not watch.
///
/// Read from the card, not from the last answer: if fetching a finished
/// bill's result fails, the card still shows it being read, says so here,
/// and the next request answers at once so the phone tries again. After a
/// restart the persisted card gives the same answer.
///
/// [lastAnswer] is the last `cardState` the server sent for this bill. It
/// is used only for the issue count of a finished, unsaved bill: the card
/// does not redraw when that count moves (only reaching 0 matters), so the
/// phone sends the count it has been told, or it would be "different" on
/// every request.
String? cardSeenState(BatchItem item, {String? lastAnswer}) {
  switch (item.status) {
    case BatchItemStatus.processing:
      if (item.isRetrying) return 'retrying:${item.retryAttempt}';
      return item.processingSince != null ? 'processing' : 'queued';
    case BatchItemStatus.pendingConfirm:
    case BatchItemStatus.needsReview:
      if (lastAnswer != null && lastAnswer.startsWith('done:unsaved:')) return lastAnswer;
      if (item.status == BatchItemStatus.pendingConfirm) return 'done:unsaved:0';
      final flags = item.result?.issues.where((i) => i.field != 'seller_gstin').length ?? 0;
      return 'done:unsaved:$flags';
    default:
      return null;
  }
}
