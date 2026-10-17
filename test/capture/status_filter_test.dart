import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gst_bill_app/features/capture/widgets/status_filter_bar.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/status_filter.dart';

/// DAS-26, mobile half. The categories mirror shop_webapp/test/statusFilter.test.js
/// — the two clients must agree on what each category means. The BOXES no
/// longer match it: since DAS-71 a bill being read and a flagged bill are one
/// box, "Processing", and the web app is left as it was for now.

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

  test('the categories and their labels (the web app\'s) are unchanged underneath the boxes', () {
    expect(kStatusFilters.map((f) => f.key).toList(), [
      'tocrop', 'working', 'check', 'review',
      'saved', 'failed',
    ]);
    expect(kStatusFilters.map((f) => f.label).toList(), [
      'To crop', 'Working', 'Not saved', 'Needs review', 'Saved', 'Failed',
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

  test('a card sitting out a backoff is working, and only that', () {
    /* It still carries the status it had, so without this it would also
       show under "Reading" — and someone filtering for what is actively
       being read would be shown work that is stalled. */
    final backoff = _item(BatchItemStatus.processing, retryAt: DateTime.now());
    expect(matchesStatusFilter(backoff, 'working'), isTrue);
    expect(matchesStatusFilter(backoff, 'check'), isFalse);
    expect(filterByStatus([backoff], {'check'}), isEmpty);
    expect(filterByStatus([backoff], {'working'}), hasLength(1));
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
    expect(counts['working'], isNull);
    // What a count claims must be what ticking it shows.
    for (final entry in counts.entries) {
      expect(filterByStatus(items, {entry.key}), hasLength(entry.value));
    }
  });

  group('the boxes (DAS-71)', () {
    test('every category is in exactly one box, so nothing is lost or counted twice', () {
      final keys = [for (final b in kFilterBoxes) ...b.keys];
      expect(keys.toSet(), kStatusFilters.map((f) => f.key).toSet());
      expect(keys, hasLength(keys.toSet().length));
    });

    test('a bill being read and a flagged bill share the box "Processing"', () {
      final box = kFilterBoxes.singleWhere((b) => b.label == 'Processing');
      expect(box.keys, ['working', 'review']);
      expect(kFilterBoxes.any((b) => b.label == 'Needs review' || b.label == 'Working'), isFalse);
    });

    Widget bar(Map<String, int> counts, Set<String> selected, ValueChanged<Set<String>> onChanged) => MaterialApp(
          home: Scaffold(body: StatusFilterBar(items: const [], counts: counts, selected: selected, onChanged: onChanged)),
        );

    testWidgets('the box adds the two categories together', (tester) async {
      await tester.pumpWidget(bar({'working': 3, 'review': 4, 'check': 2}, {}, (_) {}));
      expect(find.text('Processing 7'), findsOneWidget);
      expect(find.text('Not saved 2'), findsOneWidget);
      expect(find.textContaining('Needs review'), findsNothing);
    });

    testWidgets('ticking it selects both categories, and clearing it removes both', (tester) async {
      var selected = <String>{};
      await tester.pumpWidget(bar({'working': 1, 'review': 1}, selected, (next) => selected = next));
      await tester.tap(find.text('Processing 2'));
      expect(selected, {'working', 'review'});

      await tester.pumpWidget(bar({'working': 1, 'review': 1}, selected, (next) => selected = next));
      await tester.tap(find.text('Processing 2'));
      expect(selected, isEmpty);
    });
  });
}
