import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../models/batch_item.dart';
import '../models/list_entry.dart';
import '../models/status_filter.dart';
import '../models/upload_summary.dart';
import 'batch_item_card.dart' show ChromeButton;
import 'bill_thumbnail.dart';
import 'selection_mark.dart';

/// Every bill, in ONE list: the ones this device holds and the shop's own.
///
/// This device could only ever show what was photographed on it, so a
/// reinstall, a second handset, or a new login saw an empty screen however
/// much history the shop had — one shop had 214 uploads and saw none of
/// them. Then the shop's bills were listed too, but UNDER the device's own
/// in a separate group, and a bill moved between the two the moment it was
/// opened.
///
/// Now both are cards in the same grid, sorted by upload order and nothing
/// else, so there is no "which copy is this" to notice — and no jumping.
/// The web app's `UploadHistory.jsx` does the same.
///
/// A bill already on this device is left out of the shop's half rather
/// than drawn twice — matched on its photo path, the one thing both sides
/// agree on.
class UploadHistory extends StatefulWidget {
  /// Bills held on this device, so theirs are not listed twice.
  final List<BatchItem> localItems;

  /// Which folder is open; null is home. A bill belongs to the folder it
  /// was saved into, and an unsaved one belongs at home.
  final int? folderId;

  /// The status boxes currently ticked. Empty means everything.
  final Set<String> selected;

  /// Open a bill from the shop's list through the normal confirm / review /
  /// save flow, without adding it to this device's own bills.
  final Future<void> Function(UploadSummary upload) onOpen;

  /// This device's own bills as cards, ready to draw. Built by the screen,
  /// which owns what tapping, retrying and removing them does.
  final List<ListEntry> localEntries;

  /// Whether a tap picks a bill instead of opening it, and which are
  /// picked. Opening and picking are different intents; one gesture cannot
  /// mean both.
  final bool choosing;
  final Set<String> chosen;
  final void Function(String id)? onToggle;

  /// What is on screen, in order. The screen needs it for "Select all" and
  /// for acting on exactly what the shopkeeper can see — and to decide
  /// whether it is REALLY empty: a phone with no bills of its own drew
  /// "Photograph a supplier bill" over a shop with 214 of them.
  ///
  /// [settled] is false until the first page has arrived (or failed), so an
  /// empty list that is merely still loading is not mistaken for no bills.
  ///
  /// [counts] tallies the shop's bills in this folder by category, NOT yet
  /// narrowed by the ticked boxes — what a box would show if ticked, which
  /// is what the number on it means.
  final void Function(
    List<ListEntry> entries, {
    required bool more,
    required bool settled,
    required Map<String, int> counts,
  })? onEntries;

  /// How many bills each folder holds (`null` is home), over the whole shop —
  /// counted from the bills this list holds once they are all loaded, and
  /// from the server's tally before that, so a folder tile reads the same
  /// number whether or not anyone has scrolled to the bottom, and changes at
  /// once when bills are moved.
  final void Function(Map<int?, int> totals)? onFolderTotals;

  /// Read this bill again. Offered on the cards that want a second look —
  /// the ones that failed and the ones that need review — and never while
  /// bills are being chosen.
  final void Function(UploadSummary upload)? onRetry;

  /// The ✕ on a bill. Every PROCESSED bill wears one — clean, needing review,
  /// saved or failed — and none that is still being read. The screen decides
  /// what tapping it does (a saved bill is deleted from the bill itself).
  final void Function(UploadSummary upload)? onDelete;

  /// How to fetch a page. Defaults to the real client; injectable so the
  /// list can be driven in a test without a network, the same way
  /// BillThumbnail takes its loader.
  final Future<UploadPage> Function({int limit, int? beforeId})? fetch;

  /// The same, narrowed by the server to [categories] in [folder] (`root` or
  /// an id). Used while a status box is ticked.
  final Future<UploadPage> Function({
    int limit,
    int? beforeId,
    Set<String> categories,
    String? folder,
  })? fetchFiltered;

  const UploadHistory({
    super.key,
    required this.localItems,
    required this.folderId,
    required this.selected,
    required this.onOpen,
    this.localEntries = const [],
    this.choosing = false,
    this.chosen = const {},
    this.onToggle,
    this.onEntries,
    this.onFolderTotals,
    this.onRetry,
    this.onDelete,
    this.fetch,
    this.fetchFiltered,
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

  /// Bumped whenever the list starts over, so an answer to a question asked
  /// of the old filter is never added to the new one.
  int _generation = 0;

  /// The status boxes the SERVER narrows by. `tocrop` is a state only this
  /// phone has, so it is never asked of the server.
  static const _serverBoxes = {'working', 'check', 'review', 'saved', 'failed'};
  Set<String> get _categories => widget.selected.intersection(_serverBoxes);

  /// While a box is ticked the list holds only what the server returned for
  /// it, so what it holds is NOT the shop — counts must come from the tally.
  bool get _narrowed => _categories.isNotEmpty;

  /// The view still on screen while the answer to a NEW one is awaited: the
  /// boxes and folder it was drawn for. Without it, ticking a box blanked the
  /// grid (the rows held were filtered by the new boxes, usually to nothing,
  /// or cleared outright) until the server answered, then filled it — a flash
  /// of empty on every tick. Now the old view stays until the new rows arrive
  /// and replace it in one step.
  ({Set<String> boxes, int? folder})? _held;

  /// The server's tally of the whole shop, taken with the newest page — what
  /// lets a box say 74 before 74 bills have been scrolled to. Kept in step
  /// with discards and moves done here; null until a server that sends it
  /// has answered, when the loaded bills are tallied instead.
  Map<String, Map<String, int>>? _tally;

  static String _folderKey(int? id) => id == null ? 'root' : '$id';

  void _takeTally(Map<String, Map<String, int>>? counts) {
    if (counts == null) return;
    _tally = {for (final e in counts.entries) e.key: {...e.value}};
  }

  /// Move one bill between boxes in the held tally.
  void _shift(UploadSummary u, {int? toFolder, bool gone = false}) {
    final tally = _tally;
    if (tally == null) return;
    final category = uploadCategory(u);
    final from = tally[_folderKey(u.folderId)];
    if (from != null && (from[category] ?? 0) > 0) from[category] = from[category]! - 1;
    if (!gone) {
      final to = tally.putIfAbsent(_folderKey(toFolder), () => {});
      to[category] = (to[category] ?? 0) + 1;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  @override
  void didUpdateWidget(UploadHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.selected.intersection(_serverBoxes);
    final after = _categories;
    // A different set of boxes starts over, asked of the server. A different
    // folder does too, but only while narrowed: unnarrowed, the whole shop is
    // held and a folder is just a view of it.
    final changed = before.length != after.length || !before.containsAll(after) ||
        (after.isNotEmpty && oldWidget.folderId != widget.folderId);
    if (changed) {
      // Keep drawing what was drawn; remember the EARLIEST view if the shop
      // keeps ticking before the first answer is back.
      _held ??= (boxes: oldWidget.selected, folder: oldWidget.folderId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _swap();
      });
    }
  }

  /// Ask for the first page of the new view and replace the rows in ONE step —
  /// unlike [reload], which empties the list first.
  Future<void> _swap() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetchPage(beforeId: null);
      if (!mounted || generation != _generation) return;
      setState(() {
        _takeTally(page.counts);
        _uploads
          ..clear()
          ..addAll(page.uploads);
        _nextBeforeId = page.nextBeforeId;
        _loadedOnce = true;
        _held = null;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e.toString();
        _held = null;
      });
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  /// Called by the screen when a bill is saved or removed, so the list
  /// stops disagreeing with the grid above it.
  Future<void> reload() async {
    _generation++;
    _loading = false;
    setState(() {
      _uploads.clear();
      _nextBeforeId = null;
      _loadedOnce = false;
      // The tally is NOT cleared. The numbers on the boxes are the server's
      // count of the whole shop, which a different filter does not change;
      // clearing it made them fall back to counting the few bills loaded so
      // far — so ticking "Needs review" showed 13 for as long as the request
      // took. They stay as they were until the answer replaces them.
      _error = null;
    });
    await _loadMore();
  }

  /// Fold the newest page into what is already held, WITHOUT emptying the
  /// list. [reload] clears first, which sends the scroll position back to
  /// the top — fine for a pull-to-refresh, wrong for "I looked at a bill
  /// and came back", which is meant to leave you exactly where you were.
  ///
  /// Held rows are updated in place (a bill may have been read, saved or
  /// filed), new uploads arrive at the top, and a held row that falls
  /// inside the page's range but is missing from it has gone — discarded,
  /// or moved out — so it is dropped rather than left to linger.
  Future<void> refresh() async {
    try {
      final generation = _generation;
      final page = await _fetchPage(beforeId: null);
      if (!mounted || generation != _generation) return;
      setState(() {
        _takeTally(page.counts);
        final fresh = {for (final u in page.uploads) u.jobId: u};
        // The oldest row this page reaches. Past the end of the list the
        // whole shop is in view, so nothing absent can still exist.
        final reach = page.nextBeforeId == null || page.uploads.isEmpty
            ? -1
            : page.uploads.map((u) => u.jobId).reduce((a, b) => a < b ? a : b);

        _uploads.removeWhere((u) => u.jobId >= reach && !fresh.containsKey(u.jobId));
        for (var i = 0; i < _uploads.length; i++) {
          final updated = fresh.remove(_uploads[i].jobId);
          if (updated != null) _uploads[i] = updated;
        }
        _uploads.insertAll(0, fresh.values);
      });
    } catch (_) {
      // Best effort: what is on screen is still correct enough, and the
      // next scroll or visit will try again.
    }
  }

  /// A bill the shopkeeper discarded: gone from the list at once, rather
  /// than waiting for the next refresh — which only reaches the newest page
  /// and so would leave an older discarded bill on screen.
  void forget(Iterable<int> jobIds) {
    final gone = jobIds.toSet();
    if (gone.isEmpty) return;
    setState(() {
      for (final u in _uploads.where((u) => gone.contains(u.jobId))) {
        _shift(u, gone: true);
      }
      _uploads.removeWhere((u) => gone.contains(u.jobId));
    });
  }

  /// A bill the server already counts changed box — one finished reading, or
  /// was sent to be read again. Moves one from [from] to [to] in the held
  /// tally at once, so the numbers on the boxes change as it happens instead
  /// of when the server is next asked (which is soon after, and replaces
  /// this with the truth). Either may be a box the server does not keep
  /// (`tocrop`), which is then simply not touched.
  void shiftCategory(int? folderId, String? from, String? to) {
    final tally = _tally;
    if (tally == null || from == to) return;
    setState(() {
      final bucket = tally.putIfAbsent(_folderKey(folderId), () => {});
      if (from != null && (bucket[from] ?? 0) > 0) bucket[from] = bucket[from]! - 1;
      if (to != null && _serverBoxes.contains(to)) bucket[to] = (bucket[to] ?? 0) + 1;
    });
  }

  /// Bills put back after [forget] took them away too soon — the server
  /// refused to discard them. Added to the list and to the held tally again.
  void restore(Iterable<UploadSummary> uploads) {
    final held = _uploads.map((u) => u.jobId).toSet();
    final back = [for (final u in uploads) if (!held.contains(u.jobId)) u];
    if (back.isEmpty) return;
    setState(() {
      for (final u in back) {
        _uploads.add(u);
        final tally = _tally;
        if (tally != null) {
          final bucket = tally.putIfAbsent(_folderKey(u.folderId), () => {});
          final category = uploadCategory(u);
          bucket[category] = (bucket[category] ?? 0) + 1;
        }
      }
    });
  }

  /// Bills filed into another folder: they leave this view, or arrive in
  /// it, at once. `null` is home.
  void refile(Map<int, int?> folderByJob) {
    if (folderByJob.isEmpty) return;
    setState(() {
      for (var i = 0; i < _uploads.length; i++) {
        final id = _uploads[i].jobId;
        if (folderByJob.containsKey(id)) {
          _shift(_uploads[i], toFolder: folderByJob[id]);
          _uploads[i] = _uploads[i].withFolder(folderByJob[id]);
        }
      }
    });
  }

  Future<UploadPage> _fetchPage({int? beforeId}) {
    if (_narrowed) {
      final fetch = widget.fetchFiltered ?? ApiClient.instance.listUploads;
      return fetch(
        limit: _pageSize,
        beforeId: beforeId,
        categories: _categories,
        folder: widget.folderId == null ? 'root' : '${widget.folderId}',
      );
    }
    final fetch = widget.fetch ?? ApiClient.instance.listUploads;
    return fetch(limit: _pageSize, beforeId: beforeId);
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    if (_loadedOnce && _nextBeforeId == null) return;   // the last page is in
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetchPage(beforeId: _nextBeforeId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _takeTally(page.counts);
        _uploads.addAll(page.uploads);
        _nextBeforeId = page.nextBeforeId;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      // Never fatal: the grid above is this device's own work and must
      // keep working offline. The list says it could not load, and
      // offers to try again.
      setState(() => _error = e.toString());
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  /// The shop's bills in the folder being looked at, minus the ones this phone
  /// is DRAWING a card for — before any status box narrows them.
  ///
  /// Minus the cards actually drawn, not every bill the phone holds. A bill
  /// the phone holds but is not drawing — its own card says failed, or still
  /// processing, while the server counts it as Needs review — used to be hidden
  /// here AND by its card's status, so it was counted in a box and drawn in
  /// none ("Needs review 34", 24 listed). Now the server's row stands in
  /// whenever the phone's card is not on screen, so every bill is drawn once.
  ///
  /// A card and a row are the same bill when they share a JOB, not a photo:
  /// the same photo can be read more than once, each read its own job and its
  /// own entry in the count. Matching by photo let twenty cards hide thirty
  /// rows. A card with no job yet has no row to match; it falls back to its
  /// photo.
  List<UploadSummary> get _inFolder => _rowsNotCoveredBy(
        [for (final entry in _drawnCards) if (entry.item != null) entry.item!],
        alsoHidingInFlight: true,
      );

  /// The phone's own cards that are actually drawn.
  ///
  /// While a status box is ticked the SERVER decides what is in it — it counts
  /// the bills and it sends the rows. A phone card whose own status says
  /// "needs review" but whose bill the server now has elsewhere (it was read
  /// again and came back clean, say) must not be drawn in that box: the box
  /// said 34 and drew 39. So a card for a bill with a server job is drawn only
  /// if the server's rows for the box include that job — once every row has
  /// arrived, since until then it may simply be on a page not fetched. A card
  /// with no job yet is the phone's alone and follows its own status.
  List<ListEntry> get _drawnCards {
    if (!_narrowed || !_loadedOnce || _nextBeforeId != null || _held != null) return widget.localEntries;
    final onServer = {for (final u in _uploads) u.jobId};
    return [
      for (final entry in widget.localEntries)
        if (entry.item == null ||
            (entry.item!.lastJobId ?? entry.item!.jobId) == null ||
            onServer.contains(entry.item!.lastJobId ?? entry.item!.jobId))
          entry,
    ];
  }

  /// The shop's bills in the folder minus EVERY bill the phone holds, drawn or
  /// not — what the object-mode counts need, since the screen counts the
  /// phone's own bills itself and a bill must not be counted by both.
  List<UploadSummary> get _notHeldHere => _rowsNotCoveredBy(widget.localItems);

  List<UploadSummary> _rowsNotCoveredBy(Iterable<BatchItem> cards, {bool alsoHidingInFlight = false}) {
    final jobs = <int>{};
    final photos = <String>{};
    // A bill the phone is reading RIGHT NOW (a retry just tapped) must leave
    // every box it was in at once, though the server still lists it there until
    // its answer comes back: its row stays hidden in all boxes, and the
    // phone's own card stands in under Working.
    if (alsoHidingInFlight) {
      for (final item in widget.localItems) {
        final job = item.lastJobId ?? item.jobId;
        if (job != null && matchesStatusFilter(item, 'working')) jobs.add(job);
      }
    }
    for (final item in cards) {
      final job = item.lastJobId ?? item.jobId;
      if (job != null) {
        jobs.add(job);
      } else {
        photos.addAll(item.sourceImages);
      }
    }
    return _uploads
        .where((u) =>
            !jobs.contains(u.jobId) &&
            !photos.contains(u.sourceImage) &&
            u.folderId == (_held?.folder ?? widget.folderId))
        .toList();
  }

  /// What to draw: [_inFolder] in upload order, matching the ticked boxes.
  List<UploadSummary> get _shown {
    // Upload order, stated rather than inherited from however the pages
    // happened to arrive — a refresh inserts at the top and an update
    // replaces in place, and neither may reorder what is on screen.
    final ordered = _inFolder..sort((a, b) => b.jobId.compareTo(a.jobId));
    return filterUploads(ordered, _held?.boxes ?? widget.selected);
  }

  /// Whether the numbers come from the server's tally of the WHOLE shop, as
  /// opposed to counting the bills held here. The tally already includes
  /// every bill this phone has sent to the server, so nothing held here may
  /// be added to it a second time — see [countsCoverDeviceBills].
  bool get _tallyMode => !((!_narrowed && _loadedOnce && _nextBeforeId == null) || _tally == null);

  /// True when the counts this list reports already include this phone's
  /// bills that have reached the server (their `jobId`). The screen adds only
  /// the bills that have NOT — still being cropped or uploaded — and counts
  /// no other. Before, it added every bill the phone held on top of a total
  /// that already had them, so "Needs review" read 25 over 41.
  bool get countsCoverDeviceBills => _tallyMode;

  Map<String, int> get _counts {
    if (_tallyMode) {
      final whole = _tally?[_folderKey(widget.folderId)];
      return {...?whole}..removeWhere((_, n) => n <= 0);
    }
    final tally = <String, int>{};
    for (final u in _notHeldHere) {
      final key = uploadCategory(u);
      tally[key] = (tally[key] ?? 0) + 1;
    }
    return tally;
  }

  /// Bills per folder: the held bills counted one by one once every page is
  /// in (exact, live), the server's whole-shop tally until then.
  Map<int?, int> get _folderTotals {
    final totals = <int?, int>{};
    final tally = _tally;
    if ((!_narrowed && _loadedOnce && _nextBeforeId == null) || tally == null) {
      for (final u in _uploads) {
        totals[u.folderId] = (totals[u.folderId] ?? 0) + 1;
      }
      return totals;
    }
    tally.forEach((key, byCategory) {
      final n = byCategory.values.fold(0, (a, b) => a + b);
      if (n > 0) totals[key == 'root' ? null : int.parse(key)] = n;
    });
    return totals;
  }

  String _reportedTotals = '';
  String _reportedKey = '';

  /// Told to the screen after the frame, never during it — a parent that
  /// rebuilds mid-build is an error. Keyed on the ids, so a card changing
  /// its status does not re-announce an unchanged set.
  void _report(List<ListEntry> entries) {
    final tellTotals = widget.onFolderTotals;
    if (tellTotals != null) {
      final totals = _folderTotals;
      final signature = (totals.entries.map((e) => '${e.key}:${e.value}').toList()..sort()).join(',');
      if (signature != _reportedTotals) {
        _reportedTotals = signature;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) tellTotals(totals);
        });
      }
    }
    final tell = widget.onEntries;
    if (tell == null) return;
    final settled = _loadedOnce || _error != null;
    final counts = _counts;
    final key = '${entries.map((e) => e.id).join(',')}|${_nextBeforeId != null}|$settled|'
        '${(counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).join(',')}';
    if (key == _reportedKey) return;
    _reportedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) tell(entries, more: _nextBeforeId != null, settled: settled, counts: counts);
    });
  }

  @override
  Widget build(BuildContext context) {
    // The shop's rows are optional; this device's own cards are not. A
    // failed fetch, or "To crop" being the only box ticked, must each still
    // leave the device's own bills on screen — they used to take the whole
    // list with them.
    final showServer = wantsUploads(widget.selected);
    final serverEntries = showServer
        ? _shown.map((u) {
            final id = 'j:${u.jobId}';
            return ListEntry(
              id: id,
              sortKey: u.jobId,
              upload: u,
              card: _UploadCard(
                key: ValueKey(id),
                upload: u,
                choosing: widget.choosing,
                chosen: widget.chosen.contains(id),
                onTap: () => widget.choosing ? widget.onToggle?.call(id) : widget.onOpen(u),
                onRetry: widget.onRetry == null ? null : () => widget.onRetry!(u),
                onDelete: widget.onDelete == null ? null : () => widget.onDelete!(u),
              ),
            );
          }).toList()
        : <ListEntry>[];

    // Strictly by upload order, whichever half a card came from.
    final entries = [..._drawnCards, ...serverEntries]
      ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
    _report(entries);

    if (entries.isEmpty && !_loading && _error == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverMainAxisGroup(
      slivers: [
        if (_error != null && showServer)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Spacing.m, Spacing.m, Spacing.m, 0),
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
        // One grid and no heading: a file manager is a list of files, not a
        // "recent" group stacked over an "earlier" one.
        SliverPadding(
          padding: const EdgeInsets.all(Spacing.m),
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
                //
                // After the frame, never during it: _loadMore calls
                // setState, and a builder that does that throws "setState
                // called during build". It only shows with MORE THAN ONE
                // PAGE of bills, which is exactly the shop this exists
                // for — a shop with fifty or fewer never reaches it.
                if (i >= entries.length - 1 && _nextBeforeId != null && showServer) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _loadMore();
                  });
                }
                return entries[i].card;
              },
              childCount: entries.length,
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
  final bool choosing;
  final bool chosen;
  final VoidCallback? onRetry;
  final VoidCallback? onDelete;

  const _UploadCard({
    super.key,
    required this.upload,
    required this.onTap,
    this.choosing = false,
    this.chosen = false,
    this.onRetry,
    this.onDelete,
  });

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
            // The badge on the right and the ✕ on the left, as on this phone's
            // own cards, so a bill looks the same whichever it is.
            Positioned(top: Spacing.xs, right: Spacing.xs, child: _badge(context, category)),
            // Not on a bill still being read — only on processed ones, failed
            // included: a worker is holding that bill.
            if (onDelete != null && !choosing && category != 'working')
              Positioned(
                top: 4,
                left: 4,
                child: ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onDelete!();
                  },
                  icon: Icons.close_rounded,
                  tooltip: 'Remove this bill',
                ),
              ),
            // Read it again — for the bills that want a second look. Above
            // the date, where this phone's own cards wear theirs.
            if (onRetry != null && !choosing && (category == 'failed' || category == 'review'))
              Positioned(
                bottom: 26,
                right: Spacing.xs,
                child: ChromeButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onRetry!();
                  },
                  icon: Icons.refresh_rounded,
                  tooltip: 'Read this bill again',
                ),
              ),
            ...selectionOverlay(context, choosing: choosing, chosen: chosen),
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
