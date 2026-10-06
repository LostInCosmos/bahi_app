import 'batch_item.dart';

/// The categories a shopkeeper filters the capture grid by (DAS-26).
///
/// One definition, used for both the tickbox labels and for deciding
/// which cards a category matches, so the badge on a card can never
/// disagree with the tickbox above it.
///
/// Mirrors `shop_webapp/src/features/capture/statusFilter.js` — same
/// keys, same labels, same order — because the two clients must not
/// drift on what a shopkeeper sees.
///
/// `pendingConfirm` deliberately reads "Check & save" rather than
/// "Done": the bill was read, but nothing is saved until a human taps.
class StatusFilter {
  final String key;
  final String label;
  final Set<BatchItemStatus> statuses;

  const StatusFilter(this.key, this.label, this.statuses);
}

/// In the order a bill moves through them, so the row reads as a journey
/// rather than an alphabetised list.
const List<StatusFilter> kStatusFilters = [
  StatusFilter('tocrop', 'To crop', {BatchItemStatus.needsCrop}),
  StatusFilter('uploading', 'Uploading', {BatchItemStatus.preparing}),
  StatusFilter('queued', 'Queued', {BatchItemStatus.ready}),
  StatusFilter('reading', 'Reading', {BatchItemStatus.processing}),
  StatusFilter('retrying', 'Retrying', {}),
  StatusFilter('check', 'Check & save', {BatchItemStatus.pendingConfirm}),
  StatusFilter('review', 'Needs review', {BatchItemStatus.needsReview}),
  StatusFilter('saved', 'Saved', {BatchItemStatus.saved}),
  StatusFilter('failed', 'Failed', {BatchItemStatus.failed}),
];

/// Whether one card belongs in [key].
///
/// A bill sitting out a backoff carries [BatchItem.retryAt] on top of
/// whatever status it had, so it is matched by that rather than by
/// status — and must NOT also answer its underlying one, or someone
/// filtering for what is actively being read would be shown work that
/// is stalled.
bool matchesStatusFilter(BatchItem item, String key) {
  final retrying = item.retryAt != null;
  if (key == 'retrying') return retrying;
  if (retrying) return false;
  for (final f in kStatusFilters) {
    if (f.key == key) return f.statuses.contains(item.status);
  }
  return false;
}

/// The cards to show. An empty selection means everything — the
/// tickboxes are a filter, not a required choice.
List<BatchItem> filterByStatus(List<BatchItem> items, Set<String> selected) {
  if (selected.isEmpty) return items;
  return items
      .where((i) => selected.any((key) => matchesStatusFilter(i, key)))
      .toList();
}

/// How many cards each category would show, for the counts on the boxes.
Map<String, int> statusCounts(List<BatchItem> items) {
  final counts = <String, int>{};
  for (final item in items) {
    for (final f in kStatusFilters) {
      if (matchesStatusFilter(item, f.key)) {
        counts[f.key] = (counts[f.key] ?? 0) + 1;
      }
    }
  }
  return counts;
}
