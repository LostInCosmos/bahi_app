import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../models/batch_item.dart';

/// One bill in the capture grid: its corrected photo, a status badge, and
/// delete / reprocess controls overlaid on top.
class BatchItemCard extends StatelessWidget {
  final BatchItem item;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onReprocess;

  const BatchItemCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onDelete,
    required this.onReprocess,
  });

  @override
  Widget build(BuildContext context) {
    final pageCount = item.isUploaded ? item.sourceImages.length : item.pages.length;
    final busy = item.status == BatchItemStatus.preparing || item.status == BatchItemStatus.processing;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        onTap: busy
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.correctedBytes != null)
              Image.memory(item.correctedBytes!, fit: BoxFit.cover)
            // thumbnailFailed is checked alongside a failed item: the photo
            // can be missing on a bill that read perfectly, and either way
            // the one thing the card must not do is imply it is still coming.
            else if (item.status == BatchItemStatus.failed || item.thumbnailFailed)
              const Center(child: Icon(Icons.broken_image_outlined, size: 40, color: Colors.grey))
            else
              const Center(child: CircularProgressIndicator()),
            // Bottom scrim so the label stays legible over any photo.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 56,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.65)],
                  ),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
              child: item.status == BatchItemStatus.processing
                  ? Container(
                      key: const ValueKey('processing'),
                      color: Colors.black45,
                      child: const Center(child: CircularProgressIndicator(color: Colors.white)),
                    )
                  : const SizedBox.shrink(key: ValueKey('idle')),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: KeyedSubtree(key: ValueKey(item.status), child: _statusBadge(context)),
              ),
            ),
            if (onDelete != null)
              Positioned(
                top: 4,
                left: 4,
                child: _ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onDelete!();
                  },
                  icon: Icons.close_rounded,
                ),
              ),
            if (onReprocess != null)
              Positioned(
                bottom: 30,
                right: 6,
                child: _ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onReprocess!();
                  },
                  icon: Icons.refresh_rounded,
                  tooltip: 'Reprocess this image',
                ),
              ),
            Positioned(
              left: Spacing.s,
              right: Spacing.s,
              bottom: Spacing.s,
              child: Text(
                pageCount > 1 ? '${item.label} ($pageCount pages)' : item.label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(BuildContext context) {
    switch (item.status) {
      case BatchItemStatus.saved:
        return const _Badge(color: AppColors.statusSaved, icon: Icons.check_rounded);
      case BatchItemStatus.pendingConfirm:
        return const _Badge(color: AppColors.statusPendingConfirm, icon: Icons.touch_app_rounded);
      case BatchItemStatus.needsReview:
        return const _Badge(color: AppColors.statusNeedsReview, icon: Icons.priority_high_rounded);
      case BatchItemStatus.failed:
        return _Badge(color: Theme.of(context).colorScheme.error, icon: Icons.close_rounded);
      case BatchItemStatus.ready:
        return const _Badge(color: AppColors.statusReady, icon: Icons.hourglass_empty_rounded);
      case BatchItemStatus.preparing:
      case BatchItemStatus.processing:
        return const SizedBox.shrink();
    }
  }
}

class _Badge extends StatelessWidget {
  final Color color;
  final IconData icon;
  const _Badge({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 3)],
      ),
      child: Icon(icon, size: 15, color: Colors.white),
    );
  }
}

/// A small translucent circular icon button for controls that sit directly
/// on a photo (delete, reprocess) — its own dark chip keeps it legible on
/// light bills as well as dark ones.
class _ChromeButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String? tooltip;
  const _ChromeButton({required this.onPressed, required this.icon, this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}
