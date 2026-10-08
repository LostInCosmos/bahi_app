import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../models/batch_item.dart';
import '../models/status_filter.dart';
import '../models/upload_summary.dart';
import 'bill_thumbnail.dart';

/// The shop's own bills, under the ones this device is holding.
///
/// The capture grid above shows what was photographed on THIS phone. That
/// is all the phone could ever show: a reinstall, a second handset, or a
/// shopkeeper signing in somewhere new saw an empty screen however much
/// history the shop had — one shop had 214 uploads and saw none of them.
/// The web app grew this list first (`UploadHistory.jsx`); this is its
/// counterpart, down to the same categories and wording.
///
/// A bill already on this device is left out rather than drawn twice —
/// matched on its photo path, the one thing both sides agree on.
class UploadHistory extends StatefulWidget {
  /// Bills held on this device, so theirs are not listed twice.
  final List<BatchItem> localItems;

  /// Which folder is open; null is home. A bill belongs to the folder it
  /// was saved into, and an unsaved one belongs at home.
  final int? folderId;

  /// The status boxes currently ticked. Empty means everything.
  final Set<String> selected;

  /// Take a server bill onto this device and open it. The screen adopts
  /// it as a BatchItem, so every existing flow — confirm, review, save,
  /// move — works on it without being reimplemented here.
  final Future<void> Function(UploadSummary upload) onOpen;

  /// How many of the shop's bills this list is showing. The screen needs
  /// it to decide whether it is REALLY empty: without it, a phone with no
  /// bills of its own drew "Photograph a supplier bill" over a shop with
  /// 214 of them, because the only thing it could see was its own grid.
  final void Function(int shown)? onCount;

  /// How to fetch a page. Defaults to the real client; injectable so the
  /// list can be driven in a test without a network, the same way
  /// BillThumbnail takes its loader.
  final Future<UploadPage> Function({int limit, int? beforeId})? fetch;

  const UploadHistory({
    super.key,
    required this.localItems,
    required this.folderId,
    required this.selected,
    required this.onOpen,
    this.onCount,
    this.fetch,
  });

  @override
  State<UploadHistory> createState() => UploadHistoryState();
}

class UploadHistoryState extends State<UploadHistory> {
  static const _pageSize = 50;

  final List<UploadSummary> _uploads = [];
  int? _nextBeforeId;
  bool _loading = false;
  bool _loadedOnce = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  /// Called by the screen when a bill is saved or removed, so the list
  /// stops disagreeing with the grid above it.
  Future<void> reload() async {
    setState(() {
      _uploads.clear();
      _nextBeforeId = null;
      _loadedOnce = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    if (_loadedOnce && _nextBeforeId == null) return;   // the last page is in
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetch = widget.fetch ?? ApiClient.instance.listUploads;
      final page = await fetch(limit: _pageSize, beforeId: _nextBeforeId);
      if (!mounted) return;
      setState(() {
        _uploads.addAll(page.uploads);
        _nextBeforeId = page.nextBeforeId;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      // Never fatal: the grid above is this device's own work and must
      // keep working offline. The list says it could not load, and
      // offers to try again.
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// What to draw: the shop's bills, minus the ones already on this
  /// device, in the folder being looked at, matching the ticked boxes.
  List<UploadSummary> get _shown {
    final localPaths = <String>{
      for (final item in widget.localItems) ...item.sourceImages,
    };
    final here = _uploads.where((u) =>
        !localPaths.contains(u.sourceImage) && u.folderId == widget.folderId);
    return filterUploads(here.toList(), widget.selected);
  }

  int _reported = -1;

  /// Told to the screen after the frame, never during it — a parent that
  /// rebuilds mid-build is an error, and this is only ever read to choose
  /// between an empty state and a list.
  void _report(int count) {
    if (count == _reported) return;
    _reported = count;
    final tell = widget.onCount;
    if (tell == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) tell(count);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!wantsUploads(widget.selected)) {
      _report(0);
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final shown = _shown;
    _report(shown.length);
    if (shown.isEmpty && !_loading && _error == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Spacing.m, Spacing.l, Spacing.m, Spacing.s),
          sliver: SliverToBoxAdapter(
            child: Text(
              widget.folderId == null ? 'Earlier uploads' : 'Bills in this folder',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        if (_error != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "Couldn't load your earlier bills.",
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                  TextButton(onPressed: _loadMore, child: const Text('Try again')),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: Spacing.s,
              crossAxisSpacing: Spacing.s,
              childAspectRatio: 0.75,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                // One row from the end, ask for the next page — so the
                // list keeps up with a scroll rather than stopping at it.
                if (i >= shown.length - 1 && _nextBeforeId != null) _loadMore();
                return _UploadCard(upload: shown[i], onTap: () => widget.onOpen(shown[i]));
              },
              childCount: shown.length,
            ),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(Spacing.l),
              child: Center(child: SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          ),
      ],
    );
  }
}

class _UploadCard extends StatelessWidget {
  final UploadSummary upload;
  final VoidCallback onTap;

  const _UploadCard({required this.upload, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final category = uploadCategory(upload);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            BillThumbnail(
              sourceImage: upload.sourceImage.isEmpty ? null : upload.sourceImage,
              failed: category == 'failed',
            ),
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
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
                  ),
                ),
              ),
            ),
            Positioned(
              left: Spacing.xs,
              bottom: Spacing.xs,
              right: Spacing.xs,
              child: Text(
                _shortDate(upload.createdAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            Positioned(top: Spacing.xs, left: Spacing.xs, child: _badge(context, category)),
          ],
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, String category) {
    switch (category) {
      case 'saved':
        return const _Pill(color: AppColors.statusSaved, text: 'Saved');
      case 'review':
        // The count is the point: it says a person is needed here, and
        // how much of the bill wants looking at.
        return _Pill(color: AppColors.statusNeedsReview, text: 'Check ${upload.issueCount}');
      case 'failed':
        return _Pill(color: Theme.of(context).colorScheme.error, text: 'Failed');
      case 'working':
        return const _Pill(color: AppColors.statusReady, text: 'Working');
      default:
        return const _Pill(color: AppColors.statusPendingConfirm, text: 'Check & save');
    }
  }
}

class _Pill extends StatelessWidget {
  final Color color;
  final String text;

  const _Pill({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(100)),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

String _shortDate(DateTime when) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${when.day.toString().padLeft(2, '0')} ${months[when.month - 1]} ${when.year}';
}
