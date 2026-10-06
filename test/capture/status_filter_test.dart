import 'package:flutter_test/flutter_test.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/status_filter.dart';

/// DAS-26, mobile half. Mirrors shop_webapp/test/statusFilter.test.js —
/// the two clients must agree on what each category means, or the same
/// tickbox shows different bills on a phone and in a browser.

BatchItem _item(BatchItemStatus status, {DateTime? retryAt}) =>
    BatchItem(label: 'Photo 1', pages: const [])
      ..status = status
      ..retryAt = retryAt;

void main() {
  test('every status a card can be in has a category', () {
    /* A status with no category is a bill that vanishes the moment any
       box is ticked — invisible, and indistinguishable from "none". */
    final covered = {for (final f in kStatusFilters) ...f.statuses};
    for (final status in BatchItemStatus.values) {
      expect(covered.contains(status), isTrue, reason: 'no filter matches $status');
    }
  });

  test('each status belongs to exactly one category', () {
    for (final status in BatchItemStatus.values) {
      final hits = kStatusFilters
          .where((f) => matchesStatusFilter(_item(status), f.key))
          .map((f) => f.key)
          .toList();
      expect(hits, hasLength(1), reason: '$status matched $hits');
    }
  });

  test('the categories and labels match the web app exactly', () {
    expect(kStatusFilters.map((f) => f.key).toList(), [
      'tocrop', 'uploading', 'queued', 'reading', 'retrying', 'check', 'review',
      'saved', 'failed',
    ]);
    expect(kStatusFilters.map((f) => f.label).toList(), [
      'To crop', 'Uploading', 'Queued', 'Reading', 'Retrying', 'Check & save',
      'Needs review', 'Saved', 'Failed',
    ]);
  });

  test('nothing ticked shows everything', () {
    final items = [_item(BatchItemStatus.saved), _item(BatchItemStatus.failed)];
    expect(filterByStatus(items, {}), same(items));
  });

  test('two ticked shows the union, not the intersection', () {
    final items = [
      _item(BatchItemStatus.saved),
      _item(BatchItemStatus.failed),
      _item(BatchItemStatus.processing),
    ];
    final shown = filterByStatus(items, {'saved', 'failed'});
    expect(shown.map((i) => i.status).toList(),
        [BatchItemStatus.saved, BatchItemStatus.failed]);
  });

  test('a card sitting out a backoff is retrying, and only that', () {
    /* It still carries the status it had, so without this it would also
       show under "Reading" — and someone filtering for what is actively
       being read would be shown work that is stalled. */
    final backoff = _item(BatchItemStatus.processing, retryAt: DateTime.now());
    expect(matchesStatusFilter(backoff, 'retrying'), isTrue);
    expect(matchesStatusFilter(backoff, 'reading'), isFalse);
    expect(filterByStatus([backoff], {'reading'}), isEmpty);
    expect(filterByStatus([backoff], {'retrying'}), hasLength(1));
  });

  test('counts say how many each box would show', () {
    final items = [
      _item(BatchItemStatus.saved),
      _item(BatchItemStatus.saved),
      _item(BatchItemStatus.failed),
    ];
    final counts = statusCounts(items);
    expect(counts['saved'], 2);
    expect(counts['failed'], 1);
    expect(counts['reading'], isNull);
    // What a count claims must be what ticking it shows.
    for (final entry in counts.entries) {
      expect(filterByStatus(items, {entry.key}), hasLength(entry.value));
    }
  });
}
