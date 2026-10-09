import 'batch_item.dart';
import 'upload_summary.dart';

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
  // Uploading, queued, reading and retrying were four boxes of their own.
  // They all mean "the machine is busy, come back in a moment": a
  // shopkeeper can act on none of them and has no reason to tell them
  // apart, while nine boxes took three rows of a phone screen and pushed
  // the bills below the fold. One box — and each card's own badge still
  // says which of the four it is in.
  StatusFilter('working', 'Working', {
    BatchItemStatus.preparing,
    BatchItemStatus.ready,
    BatchItemStatus.processing,
  }),
  StatusFilter('check', 'Check & save', {BatchItemStatus.pendingConfirm}),
  StatusFilter('review', 'Needs review', {BatchItemStatus.needsReview}),
  StatusFilter('saved', 'Saved', {BatchItemStatus.saved}),
  StatusFilter('failed', 'Failed', {BatchItemStatus.failed}),
];

/// Whether one card belongs in [key].
///
/// A bill sitting out a backoff carries [BatchItem.retryAt] on top of
/// whatever status it had, so it is recognised by that rather than by
/// status. It belongs to "working" with the rest of the in-flight
/// states, and must NOT also answer the status underneath it.
bool matchesStatusFilter(BatchItem item, String key) {
  final retrying = item.retryAt != null;
  if (retrying) return key == 'working';
  for (final f in kStatusFilters) {
    if (f.key == key) return f.statuses.contains(item.status);
  }
  return false;
}

/// Which status box a bill held on this phone is in right now, if any.
String? categoryOfItem(BatchItem item) {
  for (final f in kStatusFilters) {
    if (matchesStatusFilter(item, f.key)) return f.key;
  }
  return null;
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


/// Which category a row from the shop's uploads list belongs to.
///
/// Mirrors `categoryOfJob` in the web's statusFilter.js, so a bill reads
/// the same on both. `tocrop` is never one of them: a photo awaiting its
/// corners has not been uploaded, so the server has no row for it.
String uploadCategory(UploadSummary upload) {
  if (upload.isSaved) return 'saved';
  if (upload.retryAt != null || upload.status == 'retrying') return 'working';
  switch (upload.status) {
    case 'processing':
    case 'pending':
    case 'queued':
      return 'working';
    case 'failed':
    case 'cancelled':
      return 'failed';
    case 'done':
      // What separates a bill that wants a person from one that is only
      // waiting to be saved. A server that does not send the count reads
      // as 0, which keeps the old behaviour rather than throwing.
      return upload.issueCount > 0 ? 'review' : 'check';
    default:
      return 'check';
  }
}

/// The uploads to show for a selection. Empty means everything.
List<UploadSummary> filterUploads(List<UploadSummary> uploads, Set<String> selected) {
  if (selected.isEmpty) return uploads;
  return uploads.where((u) => selected.contains(uploadCategory(u))).toList();
}

/// Whether the uploads list can hold anything for this selection at all —
/// false when the only thing ticked is a device-only state, so the list is
/// skipped rather than fetched and filtered down to nothing.
bool wantsUploads(Set<String> selected) =>
    selected.isEmpty || selected.any((key) => key != 'tocrop');
