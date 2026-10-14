import 'package:flutter/material.dart';

import '../models/batch_item.dart';
import '../models/status_filter.dart';

/// Tickboxes for the statuses a shopkeeper wants to see (DAS-26).
///
/// A filter, not a tab bar: several can be on at once, and none ticked
/// means everything rather than nothing. `FilterChip` is the Material
/// control that says exactly that, and it already announces its selected
/// state to a screen reader.
///
/// Counts cover everything on the list — this device's bills AND the
/// shop's — when the screen supplies [counts]; without them the bar counts
/// only [items], as it did when the phone could see nothing else.
class StatusFilterBar extends StatelessWidget {
  final List<BatchItem> items;

  /// What each box would show if ticked, across the whole list.
  final Map<String, int>? counts;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  const StatusFilterBar({
    super.key,
    required this.items,
    this.counts,
    required this.selected,
    required this.onChanged,
  });

  static int _countOf(FilterBox box, Map<String, int> counts) =>
      box.keys.fold(0, (sum, key) => sum + (counts[key] ?? 0));

  @override
  Widget build(BuildContext context) {
    final counts = this.counts ?? statusCounts(items);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final box in kFilterBoxes)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(_countOf(box, counts) > 0 ? '${box.label} ${_countOf(box, counts)}' : box.label),
                selected: box.keys.any(selected.contains),
                onSelected: (on) {
                  final next = {...selected};
                  if (on) {
                    next.addAll(box.keys);
                  } else {
                    next.removeAll(box.keys);
                  }
                  onChanged(next);
                },
              ),
            ),
          if (selected.isNotEmpty)
            TextButton(
              onPressed: () => onChanged(<String>{}),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}
