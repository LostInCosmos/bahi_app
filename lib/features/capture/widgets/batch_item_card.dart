import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../models/batch_item.dart';
import '../models/bill_search.dart';
import '../models/status_filter.dart' show kUnderProcessingLabel;
import '../../../core/utils/format.dart';
import 'bill_thumbnail.dart';
import 'retry_label.dart';
import 'selection_mark.dart';

/// One bill in the capture grid: its corrected photo, a status badge, and
/// delete / reprocess controls overlaid on top.
class BatchItemCard extends StatelessWidget {
  final BatchItem item;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onReprocess;
  final VoidCallback? onMove;

  /// Asks the server once whether our team has finished with this bill, or
  /// a retried extraction has since saved it cleanly (DAS-76, extended by
  /// DAS-79), the moment this card is actually built in a needsReview or
  /// pendingConfirm state — scrolling it into view included. Never called
  /// more than once per episode: see [BatchItem.recheckedThisReview].
  final void Function(BatchItem item)? onRecheckNeedsReview;

  /// Bills are being chosen: a tap picks this one, and the card wears a ring
  /// and a tick when [chosen]. The screen passes null for the delete, move
  /// and reprocess controls while this is on — acting on one bill by its own
  /// button and on a selection at once would be two ways to do the same
  /// thing on the same screen.
  final bool choosing;
  final bool chosen;

  const BatchItemCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onDelete,
    required this.onReprocess,
    this.onMove,
    this.onRecheckNeedsReview,
    this.choosing = false,
    this.chosen = false,
  });

  @override
  Widget build(BuildContext context) {
    if ((item.status == BatchItemStatus.needsReview ||
            item.status == BatchItemStatus.pendingConfirm) &&
        !item.recheckedThisReview) {
      item.recheckedThisReview = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => onRecheckNeedsReview?.call(item));
    }
    final pageCount =
        item.isUploaded ? item.sourceImages.length : item.pages.length;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        // A bill still being read opens too: its dialog offers Discard
        // (DAS-115).
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            BillThumbnail(
              sourceImage: item.isUploaded ? item.sourceImages.first : null,
              imageRev: item.result?.meta.imageRev ?? 0,
              failed: item.status == BatchItemStatus.failed,
              localPhoto: item.status == BatchItemStatus.needsCrop && item.pages.isNotEmpty
                  ? item.pages.first.loadBytes
                  : null,
            ),
            // Bottom scrim so the label stays legible over any photo.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 44,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0),
                      Colors.black.withValues(alpha: 0.65)
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) => ScaleTransition(
                  scale: anim,
                  child: FadeTransition(opacity: anim, child: child)),
              child: item.status == BatchItemStatus.processing
                  ? Container(
                      key:
                          ValueKey(item.isRetrying ? 'retrying' : 'processing'),
                      color: Colors.black45,
                      // During a retry's backoff a spinner would imply work is
                      // happening right now; it is not — the server tries
                      // again at retryAt. Say that, so a slow bill does not
                      // read as a hung one.
                      child: Center(
                        child: item.isRetrying
                            ? RetryLabel(
                                attempt: item.retryAttempt,
                                max: item.retryMax,
                                at: item.retryAt!)
                            // No spinner (DAS-71): to the shopkeeper the bill is
                            // simply with us.
                            : const Text(
                                kUnderProcessingLabel,
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700),
                              ),
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('idle')),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: KeyedSubtree(
                    key: ValueKey(item.status), child: _statusBadge(context)),
              ),
            ),
            if (onDelete != null)
              Positioned(
                top: 4,
                left: 4,
                child: ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onDelete!();
                  },
                  icon: Icons.close_rounded,
                ),
              ),
            if (onReprocess != null)
              Positioned(
                bottom: 26,
                right: 4,
                child: ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onReprocess!();
                  },
                  icon: Icons.refresh_rounded,
                  tooltip: 'Reprocess this image',
                ),
              ),
            if (onMove != null)
              Positioned(
                bottom: 26,
                left: 4,
                child: ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onMove!();
                  },
                  icon: Icons.drive_file_move_outlined,
                  tooltip: 'Move to folder…',
                ),
              ),
            ...selectionOverlay(context, choosing: choosing, chosen: chosen),
            Positioned(
              left: Spacing.xs,
              right: Spacing.xs,
              bottom: Spacing.xs,
              child: Text(
                // The shop once it has been read; the label until then. A
                // multi-page bill not sent yet says so (DAS-131).
                item.draft
                    ? '${plural(pageCount, 'page')} · not sent'
                    : pageCount > 1
                        ? '${item.shopName ?? item.label} ($pageCount pages)'
                        : (item.shopName ?? item.label),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
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
        return const _Badge(
            color: AppColors.statusSaved, icon: Icons.check_rounded);
      case BatchItemStatus.pendingConfirm:
        return const _Badge(
            color: AppColors.statusPendingConfirm,
            icon: Icons.touch_app_rounded);
      // Flagged bills are with our team, so they look like any bill still
      // waiting to be read, not like one waiting for the shopkeeper.
      case BatchItemStatus.needsReview:
      case BatchItemStatus.ready:
        return const _Badge(
            color: AppColors.statusReady, icon: Icons.hourglass_empty_rounded);
      case BatchItemStatus.failed:
        return _Badge(
            color: Theme.of(context).colorScheme.error,
            icon: Icons.close_rounded);
      case BatchItemStatus.needsCrop:
        // An instruction, not a state: this card is waiting for the
        // shopkeeper — to choose its corners, or (a draft) to send it — and
        // the icon says which.
        return _Badge(
            color: AppColors.statusNeedsReview,
            icon: item.draft ? Icons.outbox_rounded : Icons.crop_rounded);
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
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 3)
        ],
      ),
      child: Icon(icon, size: 13, color: Colors.white),
    );
  }
}

/// A small translucent circular icon button for controls that sit directly
/// on a photo (delete, reprocess) — its own dark chip keeps it legible on
/// light bills as well as dark ones.
/// The small round button a card wears in a corner — shared by this phone's
/// cards and the shop's, so they look the same.
class ChromeButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String? tooltip;
  const ChromeButton(
      {super.key, required this.onPressed, required this.icon, this.tooltip});

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
            padding: const EdgeInsets.all(4),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
        ),
      ),
    );
  }
}
