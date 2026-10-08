import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// The ring and corner tick a card wears while bills are being chosen.
///
/// Returned as a list to drop into a card's Stack, and empty when nothing is
/// being chosen, so a card pays nothing for it the rest of the time. Shared
/// by every kind of card so a bill looks the same chosen wherever it came
/// from.
List<Widget> selectionOverlay(
  BuildContext context, {
  required bool choosing,
  required bool chosen,
}) {
  if (!choosing) return const [];
  final primary = Theme.of(context).colorScheme.primary;
  return [
    // The ring, drawn over the photo but never in the way of a tap.
    Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: chosen ? Border.all(color: primary, width: 3) : null,
          ),
        ),
      ),
    ),
    // Bottom-right: the device's own cards wear their status badge in the
    // top-right corner, and a tick on top of it would hide what it says.
    Positioned(
      bottom: Spacing.xs,
      right: Spacing.xs,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('selection-mark'),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: chosen ? primary : Colors.black.withValues(alpha: 0.35),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: chosen ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
        ),
      ),
    ),
  ];
}
