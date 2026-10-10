part of 'capture_screen.dart';

/// Choosing several bills and moving or discarding them together — the
/// Select mode of [CaptureScreen], kept apart from the capture and reading
/// flow it does not touch. The rules it follows (what may be discarded, how a
/// selection splits into requests) are pure functions in `models/bulk.dart`;
/// this is the part that talks to the screen and the server.
///
/// It needs five things from the screen, declared here so the dependency is
/// written down rather than reached for.
mixin _Selection on State<CaptureScreen> {
  GlobalKey<UploadHistoryState> get _uploadHistory;
  FolderController get _folders;
  void _say(String message);
  void _dropLocal(BatchItem item);
  Future<void> _persistBatch();

  // ---- choosing several bills ----
  //
  // `_visible` is what the list last reported it is drawing, and it is the
  // ONLY thing the actions are measured against: ticking a bill and then
  // filtering it out of view must not leave it armed for a Discard the
  // shopkeeper can no longer see.
  bool _choosing = false;
  final Set<String> _chosen = {};
  List<ListEntry> _visible = const [];
  bool _visibleMore = false;
  bool _listSettled = false;
  Map<String, int> _serverCounts = const {};
  bool _bulkBusy = false;
  _MoveProgress? _moving;

  // A bill on this device has no id of its own; this gives each card one for
  // the life of the screen so a selection can name it.
  final Expando<String> _entryIds = Expando<String>();
  int _nextEntryId = 0;
  String _idOf(BatchItem item) => _entryIds[item] ??= 'l:${_nextEntryId++}';

  void _onEntries(
    List<ListEntry> entries, {
    required bool more,
    required bool settled,
    required Map<String, int> counts,
  }) {
    if (!mounted) return;
    setState(() {
      _visible = entries;
      _visibleMore = more;
      _listSettled = settled;
      _serverCounts = counts;
    });
  }

  void _toggleChosen(String id) {
    setState(() {
      if (!_chosen.remove(id)) _chosen.add(id);
    });
  }

  void _stopChoosing() {
    setState(() {
      _choosing = false;
      _chosen.clear();
    });
  }

  void _selectAll() => setState(() => _chosen.addAll(_visible.map((e) => e.id)));

  List<ListEntry> _chosenEntries() => _visible.where((e) => _chosen.contains(e.id)).toList();

  Future<void> _discardChosen() async {
    final plan = planDiscard(_chosenEntries());
    if (plan.take.isEmpty) {
      _say(summarise('Discarded', const BulkResult(0, []),
          savedLeft: plan.savedLeft, readingLeft: plan.readingLeft));
      return;
    }
    final n = plan.take.length;
    // The one confirmation in the flow: it cannot be undone from here, and
    // it reaches every device the shop signs in from.
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discard $n bill${n == 1 ? '' : 's'}?'),
        content: Text('${n == 1 ? 'It' : 'They'} will disappear from this shop on every device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final requests = planDiscardRequests(plan.take);

    // Show it gone first, as a move does. Bills that are only in the shop's
    // list leave at once and come back if the server refuses; a bill held on
    // this phone keeps its card until the server has said yes, because
    // dropping it deletes its photos and that cannot be taken back.
    final fromList = [for (final e in plan.take) if (e.upload != null) e.upload!];
    _uploadHistory.currentState?.forget(fromList.map((u) => u.jobId));
    for (final e in requests.local) {
      if (e.item != null) _dropLocal(e.item!);
    }
    final total = plan.take.length;
    setState(() {
      _chosen.clear();
      _bulkBusy = true;
      _moving = _MoveProgress('Discarding $total', total, requests.local.length, 'done');
    });

    var done = requests.local.length;
    final refused = <ListEntry>[];
    var firstError = '';
    for (final batch in requests.batches) {
      List<ListEntry> no;
      try {
        no = batch.refused(await ApiClient.instance.bulkDiscard(batch.jobIds));
      } catch (e) {
        no = batch.entries;
        if (firstError.isEmpty) firstError = '$e';
      }
      refused.addAll(no);
      final refusedIds = {for (final e in no) e.id};
      for (final e in batch.entries) {
        final item = e.item;
        if (item != null && !refusedIds.contains(e.id)) _dropLocal(item);
      }
      done += batch.entries.length - no.length;
      if (!mounted) return;
      setState(() => _moving = _MoveProgress('Discarding $total', total, done + refused.length, 'done'));
    }

    _uploadHistory.currentState?.restore([for (final e in refused) if (e.upload != null) e.upload!]);
    if (!mounted) return;
    setState(() {
      _bulkBusy = false;
      _moving = null;
    });
    final result = BulkResult(done, [for (final e in refused) BulkFailure(e, firstError.isEmpty ? 'refused' : firstError)]);
    _say(summarise('Discarded', result, savedLeft: plan.savedLeft, readingLeft: plan.readingLeft) +
        (firstError.isEmpty ? '' : ' ($firstError)'));
    unawaited(_folders.load());
  }

  Future<void> _moveChosen() async {
    final entries = _chosenEntries();
    if (entries.isEmpty) return;
    final n = entries.length;
    final choice = await showFolderPicker(
      context,
      tree: _folders.tree,
      title: 'Move $n bill${n == 1 ? '' : 's'} to…',
      currentId: _folders.currentId,
    );
    if (choice == null || !mounted) return;

    final plan = planMove(entries);
    final target = choice.folderId;
    final name = _folders.tree.byId(target)?.name ?? 'Home';

    // Show it moved FIRST. Bills used to stay where they were until the last
    // request came back — minutes, for a few hundred — and then vanished all
    // at once. Now they leave this view and arrive in the folder at once, and
    // the server catches up behind them; anything it refuses is put back.
    final before = <String, int?>{};      // where each bill was, for putting back
    final refile = <int, int?>{};
    void place(ListEntry e, int? folder) {
      final item = e.item;
      if (item != null) {
        item.folderId = folder;
      } else {
        refile[e.upload!.jobId] = folder;
      }
    }

    for (final e in entries) {
      before[e.id] = e.item?.folderId ?? e.upload!.folderId;
      place(e, target);
    }
    _uploadHistory.currentState?.refile(Map.of(refile));
    refile.clear();
    setState(() {
      _chosen.clear();
      _bulkBusy = true;
      _moving = _MoveProgress('Moving ${plan.total} to $name', plan.total, plan.local.length, 'saved');
    });

    var moved = plan.local.length;
    final refused = <ListEntry>[];
    var firstError = '';
    for (final batch in plan.batches) {
      try {
        final reply = await ApiClient.instance.bulkMove(
          jobIds: batch.jobIds,
          invoiceIds: batch.invoiceIds,
          folderId: target,
        );
        final no = batch.refused(reply);
        refused.addAll(no);
        moved += batch.entries.length - no.length;
      } catch (e) {
        refused.addAll(batch.entries);
        if (firstError.isEmpty) firstError = '$e';
      }
      if (!mounted) return;
      setState(() => _moving = _MoveProgress('Moving ${plan.total} to $name', plan.total, moved + refused.length, 'saved'));
    }

    for (final e in refused) {
      place(e, before[e.id]);
    }
    _uploadHistory.currentState?.refile(Map.of(refile));
    if (!mounted) return;
    setState(() {
      _bulkBusy = false;
      _moving = null;
    });
    await _persistBatch();
    final left = refused.length;
    _say(left == 0
        ? 'Moved $moved bill${moved == 1 ? '' : 's'} to $name.'
        : "Moved $moved to $name; $left couldn't be moved and went back"
            '${firstError.isEmpty ? ' (saved, discarded or not in this shop)' : ': $firstError'}.');
    unawaited(_folders.load());   // the tiles count what is inside them
  }
}


/// How far a move has got. Shown as a strip above the bottom bar, because
/// the bills have already moved on screen and the shopkeeper should know
/// the server is still catching up — and when it is done.
class _MoveProgress {
  /// "Moving 332 to Testing2", "Discarding 332".
  final String headline;
  final int total;
  final int done;

  /// What "done" means to the server: bills are `saved` to a folder, `done`
  /// being discarded.
  final String word;

  const _MoveProgress(this.headline, this.total, this.done, this.word);
}

class _MoveStrip extends StatelessWidget {
  final _MoveProgress progress;

  const _MoveStrip(this.progress);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('move-progress'),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${progress.headline} · ${progress.done} of ${progress.total} ${progress.word}',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress.total == 0 ? null : progress.done / progress.total),
          ],
        ),
      ),
    );
  }
}
