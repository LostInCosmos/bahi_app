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
/// Counts come from the cards on this device, which on mobile is all
/// there is — the phone does not read the shop-wide uploads list.
class StatusFilterBar extends StatelessWidget {
  final List<BatchItem> items;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  const StatusFilterBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final counts = statusCounts(items);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final f in kStatusFilters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(
                  (counts[f.key] ?? 0) > 0 ? '${f.label} ${counts[f.key]}' : f.label,
                ),
                selected: selected.contains(f.key),
                onSelected: (on) {
                  final next = {...selected};
                  if (on) {
                    next.add(f.key);
                  } else {
                    next.remove(f.key);
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
