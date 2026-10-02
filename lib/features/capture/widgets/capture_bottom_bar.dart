import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';

/// "Add another" / gallery buttons once the batch has items, plus either the
/// finish button (every bill saved) or a nudge that some still need a look.
class CaptureBottomBar extends StatelessWidget {
  final bool hasItems;
  final bool allResolved;
  final bool hasUnresolved;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickFromGallery;
  final VoidCallback onFinish;

  const CaptureBottomBar({
    super.key,
    required this.hasItems,
    required this.allResolved,
    required this.hasUnresolved,
    required this.onTakePhoto,
    required this.onPickFromGallery,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, -2))],
      ),
      padding: const EdgeInsets.fromLTRB(Spacing.m, Spacing.m, Spacing.m, Spacing.m),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasItems) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onTakePhoto,
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: const Text('Add another'),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  IconButton.filledTonal(
                    onPressed: onPickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    tooltip: 'Add from gallery',
                  ),
                ],
              ),
              const SizedBox(height: Spacing.s),
            ],
            // Every bill starts processing on its own as soon as it's cropped,
            // so nothing here waits on a manual "Process" step — this only
            // ever shows "you're all done" or "something still needs a look".
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: allResolved
                  ? FilledButton.icon(
                      key: const ValueKey('done'),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        onFinish();
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Done — view purchases'),
                    )
                  : hasUnresolved
                      ? Padding(
                          key: const ValueKey('attention'),
                          padding: const EdgeInsets.symmetric(vertical: Spacing.s),
                          child: Text(
                            'Some bills need your attention above before you can finish.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.error),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ],
        ),
      ),
    );
  }
}
