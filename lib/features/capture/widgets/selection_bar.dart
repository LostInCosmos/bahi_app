import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// What replaces the Take-photo bar while bills are being chosen.
///
/// Swapped in rather than stacked above it: two bars would take a third of a
/// phone screen, and "take a photo" is not something to do mid-selection.
class SelectionBar extends StatelessWidget {
  final int count;

  /// More bills exist below than are loaded — "Select all" takes what is
  /// loaded, so say so rather than let it look like the whole shop.
  final bool more;
  final bool busy;
  final VoidCallback onSelectAll;
  final VoidCallback onMove;
  final VoidCallback onDiscard;

  const SelectionBar({
    super.key,
    required this.count,
    required this.more,
    required this.busy,
    required this.onSelectAll,
    required this.onMove,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final none = count == 0;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.m, vertical: Spacing.s),
        child: Row(
          children: [
            Expanded(
              child: Text(
                more ? '$count selected · more below' : '$count selected',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(onPressed: busy ? null : onSelectAll, child: const Text('Select all')),
            OutlinedButton(onPressed: busy || none ? null : onMove, child: const Text('Move')),
            const SizedBox(width: Spacing.s),
            FilledButton(onPressed: busy || none ? null : onDiscard, child: const Text('Discard')),
          ],
        ),
      ),
    );
  }
}
