part of 'capture_screen.dart';

/// Watching the bills the server is reading: the batch long-poll (DAS-19),
/// what each answer does to a card, and picking up a save that happened
/// somewhere else (DAS-76, DAS-79). Both of those bugs were about when a job
/// stops being watched, which is why this lives on its own.
///
/// It needs six things from the screen, declared here so the dependency is
/// written down rather than reached for.
mixin _Watching on State<CaptureScreen> {
  List<BatchItem> get _items;
  Future<void> _persistBatch();
  Future<void> _persistBatchIfChanged();
  void _noteMove(BatchItem item, String? before);
  void _scheduleListRefresh();

  /// Bills this phone handed over to the shop's list unsaved (DAS-62): no
  /// card any more, but still watched by job until saved, so a save by our
  /// team refreshes the list without waiting for a pull (DAS-79).
  Set<int> get _watchedRows;

  // There is NO client-side limit on how long a bill may be read. The phone
  // used to give up after a fixed time and mark the bill failed, and the
  // server went on to finish it: first at 120 s (set when a bill was one model
  // call), then every limit is wrong again as soon as a bill takes more calls
  // or the provider is busy. The server is the one that knows — it reclaims a
  // job nobody is working on and fails it after its attempts — so the card
  // shows what the server says, however long that takes.
  // The server's reconciler re-queues a due retry on a 60s sweep, so pickup
  // can lag `retryAt` by up to that much.
  static const _retrySweepMargin = Duration(seconds: 60);

  bool _statusLoopRunning = false;

  /// The last state the server reported for each watched job, as its
  /// `cardState` (DAS-132). It fills two gaps in what a card can say for
  /// itself: the issue count of a finished bill, and the rows watched by job
  /// after a hand-over, which have no card at all. Without an entry a job is
  /// left out of `seen`, which the server counts as changed: one quick answer,
  /// after which the entry exists.
  final Map<int, String> _lastAnswers = {};

  /// What the phone draws for each of [ids], for the request's `seen`.
  Map<int, String> _seenFor(Iterable<int> ids, Map<int, BatchItem> watching) {
    final seen = <int, String>{};
    for (final id in ids) {
      final item = watching[id];
      final state = item == null ? _lastAnswers[id] : cardSeenState(item, lastAnswer: _lastAnswers[id]);
      if (state != null) seen[id] = state;
    }
    return seen;
  }

  /// Public so HomeScreen can ask again when this tab is reopened (DAS-76):
  /// a card held in needsReview or pendingConfirm otherwise only rechecks
  /// itself once it is actually (re)built — reopening the tab alone does not
  /// do that, since IndexedStack keeps the grid's cards mounted rather than
  /// rebuilding them. Covers pendingConfirm too (DAS-79): a clean bill whose
  /// own save attempt once failed can be saved by an admin's retried
  /// extraction exactly the way a flagged one can be saved by a correction,
  /// and either way this phone may not have been watching for it (the live
  /// loop only started if something was already in flight when the screen
  /// opened).
  Future<void> recheckNeedsReview() async {
    // The shop's rows — every bill this phone no longer holds a card for —
    // are brought up to date the same way.
    _scheduleListRefresh();
    final held = {
      for (final item in _items)
        if ((item.status == BatchItemStatus.needsReview ||
                item.status == BatchItemStatus.pendingConfirm) &&
            (item.lastJobId ?? item.jobId) != null)
          (item.lastJobId ?? item.jobId)!: item,
    };
    if (held.isEmpty) return;

    // One status request for every held card (DAS-105): its brief says
    // whether the bill was saved meanwhile and how many flags are left, so
    // only a bill that actually changed costs a result fetch. Before, every
    // held card fetched its full result on each tab reopen.
    final JobStatusBatch batch;
    try {
      batch = await ApiClient.instance.jobStatuses(held.keys.toList(), wait: false);
    } catch (_) {
      return; // best-effort, like the per-card check
    }
    if (!mounted) return;
    for (final brief in batch.jobs) {
      final item = held[brief.jobId];
      if (item == null) continue;
      if (brief.saved) {
        await _applyAutoSave(item, brief);
        if (item.status == BatchItemStatus.saved) {
          unawaited(_persistBatch());
          _scheduleListRefresh();
        }
      } else if (brief.flagCount == null) {
        // An older server: no count in the brief, ask the bill itself.
        await _recheckNeedsReview(item);
      } else if (item.status == BatchItemStatus.needsReview && brief.flagCount == 0) {
        // Our team cleared the last flag: fetch the corrected result once.
        await _recheckNeedsReview(item);
      }
      if (!mounted) return;
    }
  }

  /// One bill our team, or an admin's retried extraction, might have
  /// resolved while nothing was watching it (DAS-76, extended by DAS-79) —
  /// reuses the exact
  /// "is it still flagged" rule the first terminal transition already uses,
  /// so this never disagrees with it. Best-effort: a failure here just means
  /// the next ask (another scroll, another tab reopen) tries again, same as
  /// any other background refresh.
  Future<void> _recheckNeedsReview(BatchItem item) async {
    if (item.status != BatchItemStatus.needsReview &&
        item.status != BatchItemStatus.pendingConfirm) {
      return;
    }
    final jobId = item.lastJobId ?? item.jobId;
    if (jobId == null) return;
    try {
      final job = await ApiClient.instance.getExtractionJob(jobId);
      if (!mounted) return;
      if (job.isAlreadySaved) {
        setState(() {
          item.jobId = null;
          item.status = BatchItemStatus.saved;
          item.savedInvoiceId = job.invoiceId;
          if (job.result != null) item.result = job.result;
        });
        unawaited(_persistBatch());
        _scheduleListRefresh();
        return;
      }
      if (item.status != BatchItemStatus.needsReview) return;
      final result = job.result;
      if (result == null) return;
      final stillFlagged = result.issues.any((i) => i.field != 'seller_gstin');
      if (stillFlagged) return;
      setState(() {
        item.result = result;
        item.status = BatchItemStatus.pendingConfirm;
      });
      unawaited(_persistBatch());
      _scheduleListRefresh();
    } catch (_) {
      // ignored — see doc comment
    }
  }

  /// Submits a bill for extraction, or adopts an id already in flight. Does
  /// not wait — [_statusLoop] watches every in-flight bill together.
  Future<void> _processOne(BatchItem item, {int? resumeJobId}) async {
    final held = _items.contains(item);
    final before = categoryOfItem(item);
    setState(() {
      item.status = BatchItemStatus.processing;
      item.processingSince = null;
    });
    _noteMove(item, before);
    try {
      int jobId;
      if (resumeJobId != null) {
        jobId = resumeJobId;
      } else if (item.lastJobId != null) {
        // Not this item's first attempt — reuse its existing row rather than
        // creating a separate one on every retry.
        try {
          jobId = await ApiClient.instance.retryExtraction(item.lastJobId!);
        } on ApiException catch (e) {
          // 409: the server is ALREADY working on it — typically retrying a
          // read on its own after this screen had stopped waiting. That is
          // the answer the user wanted, not an error: resume watching that
          // job instead of showing a failure they cannot get past.
          if (e.statusCode != 409) rethrow;
          jobId = item.lastJobId!;
        }
        item.jobId = jobId;
      } else {
        jobId = await ApiClient.instance.submitExtraction(
          item.sourceImages.first,
          extraSourceImages: item.sourceImages.skip(1).toList(),
        );
        item.jobId = jobId;
        item.lastJobId = jobId;
        // It has a job now, so the server counts it; ask for the numbers that
        // include it rather than leave it uncounted until something else does.
        _scheduleListRefresh();
      }
      if (held && !_items.contains(item)) {
        // Discarded while its read was being asked for (DAS-115): the server
        // has a job nobody here holds, so it is discarded there too.
        unawaited(ApiClient.instance.bulkDiscard([jobId]).then((_) {}, onError: (_) {}));
        return;
      }
      await _persistBatch();
      _ensureStatusLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() => item.markFailed(e.toString()));
      await _persistBatch();
    }
  }

  /// One request watches the whole batch, instead of a 2-second timer per
  /// bill. At a hundred bills that was fifty requests a second, each one a
  /// full row of result JSON to deliver a word of status; this is one held
  /// request for all of them, answered the moment anything changes.
  void _ensureStatusLoop() {
    if (_statusLoopRunning) return;
    _statusLoopRunning = true;
    unawaited(_statusLoop().whenComplete(() {
      _statusLoopRunning = false;
      // A bill submitted while the loop was winding down saw the flag still
      // set and did not start one. Without this it would be watched by
      // nobody and spin for ever.
      if (mounted && (_watching.isNotEmpty || _watchedRows.isNotEmpty)) {
        _ensureStatusLoop();
      }
    }));
  }

  /// A bill is watched while it is being read, AND after — a pendingConfirm
  /// (its own save attempt failed) or flagged bill stays `done` forever as
  /// far as [status] is concerned, but can still be saved later by an admin
  /// action nobody on this phone did anything to trigger (DAS-79). [jobId]
  /// is only cleared once a bill is actually saved or failed, so it keeps
  /// its place here until then.
  Map<int, BatchItem> get _watching => {
        for (final i in _items)
          if (i.jobId != null &&
              (i.status == BatchItemStatus.processing ||
                  i.status == BatchItemStatus.pendingConfirm ||
                  i.status == BatchItemStatus.needsReview))
            i.jobId!: i,
      };

  Future<void> _statusLoop() async {
    var idleRounds = 0;
    while (mounted) {
      final watching = _watching;
      final rows = _watchedRows.difference(watching.keys.toSet());
      if (watching.isEmpty && rows.isEmpty) {
        // Nothing to ask about. Costs no request at all; a few local ticks
        // then stop, and the next submission starts the loop again.
        if (++idleRounds > 3) return;
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      idleRounds = 0;

      // A bill the server is backing off on is not worth asking about until
      // it is due; it would only return "retrying" again.
      final due = [
        for (final e in watching.entries)
          if (!e.value.isBackingOff(_retrySweepMargin)) e.key,
        ...rows,
      ];
      if (due.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }

      // Not asked while the app is away (DAS-131). Android cuts a
      // backgrounded app's sockets after 5 s and refuses new ones, so asking
      // only spins; the first request after return re-reads current state.
      if (!AppForeground.visible.value) {
        await AppForeground.untilVisible();
        continue;
      }

      final away = AppForeground.awayCount;
      final seen = _seenFor(due, watching);
      final askedAt = DateTime.now();
      final JobStatusBatch batch;
      try {
        batch = await ApiClient.instance.jobStatuses(due, seen: seen);
      } catch (_) {
        // A dropped connection is expected on mobile and is NOT a failed
        // bill: the server holds the request open for ~25s, so a tunnel or a
        // wifi-to-cellular switch lands here routinely. Ask again — every
        // request re-reads current state, so nothing that happened while we
        // were away is lost.
        if (!mounted) return;
        // Cut because the app left the screen: ask again the moment it is
        // back, with no pause.
        if (!AppForeground.visible.value || AppForeground.awayCount != away) continue;
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      if (!mounted) return;

      var finished = false;
      for (final brief in batch.jobs) {
        _lastAnswers[brief.jobId] = brief.cardState;
        final item = watching[brief.jobId];
        if (item == null && brief.saved && _watchedRows.remove(brief.jobId)) {
          // Saved by our team after this phone handed the bill over: the
          // shop's row says so once the list is asked.
          finished = true;
        } else if (item != null) {
          final before = categoryOfItem(item);
          if (item.status == BatchItemStatus.processing) {
            await _applyStatus(item, brief);
          } else if (brief.saved) {
            // Already pendingConfirm/needsReview, and the server has now
            // saved it without this phone doing anything (DAS-79).
            await _applyAutoSave(item, brief);
          }
          // Not `brief.isTerminal`: that stays true for every round of an
          // unsaved done job, which would schedule a refresh every ~25s for
          // nothing. Only a genuine move is worth one.
          _noteMove(item, before);
          if (categoryOfItem(item) != before) finished = true;
        }
      }
      // A bill finishing changes what the boxes should say, and the list's
      // tally is the SERVER's — which only moves when it is asked again. Ten
      // bills retried together left "Working 10" over an empty list after the
      // server had finished all of them.
      if (finished) _scheduleListRefresh();
      // Most rounds change nothing: the server held the request ~25s and
      // answered that nobody moved. Rewriting the whole batch then cost a
      // 1.6 MB encode and write every round for a 300-bill batch (DAS-92).
      await _persistBatchIfChanged();
      if (!mounted) return;

      final stillWatched = {..._watching.keys, ..._watchedRows};
      _lastAnswers.removeWhere((id, _) => !stillWatched.contains(id));
      // The server answered at once because the cards differ from it, and
      // they still do: this phone could not act on the answer (a result fetch
      // that failed) or reads a state differently from the server. Asking
      // again at once would loop as fast as the network allows, so pause as
      // after a dropped request.
      if (DateTime.now().difference(askedAt) < const Duration(seconds: 1) &&
          mapEquals(_seenFor(due, _watching), seen)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Folds one bill's reported state into its card.
  Future<void> _applyStatus(BatchItem item, JobStatusBrief brief) async {
    if (brief.isRetrying) {
      setState(() {
        item.retryAttempt = brief.attempt;
        item.retryMax = brief.maxAttempts;
        item.retryAt = brief.retryAt ?? DateTime.now().toUtc();
        item.processingSince = null;
      });
      return;
    }
    if (!brief.isTerminal) {
      setState(() {
        item.retryAt = null;
        if (brief.isProcessing) {
          item.processingSince ??= DateTime.now().toUtc();
        } else {
          // Back to queued: whatever the last attempt had done is void.
          item.processingSince = null;
        }
      });
      return;
    }

    // Terminal. The full result is fetched once, here, rather than being
    // carried on every status answer.
    try {
      final job = await ApiClient.instance.getExtractionJob(brief.jobId);
      if (!mounted) return;
      if (job.status == 'done' && job.isAlreadySaved) {
        // Clean before this phone ever looked at it — the server saved it
        // already (DAS-79). No tap, no pendingConfirm.
        setState(() {
          item.jobId = null;
          item.retryAt = null;
          item.processingSince = null;
          item.status = BatchItemStatus.saved;
          item.savedInvoiceId = job.invoiceId;
          item.result = job.result;
        });
        return;
      }
      final ExtractionResult result;
      if (job.status == 'done') {
        result = job.result!;
      } else if (job.errorKind == 'structural_validation_failed') {
        result = ExtractionResult.blank(
          job.sourceImage ?? item.sourceImages.first,
          job.errorMessage ??
              "Automatic extraction couldn't read this bill — please enter its details by hand.",
          extraSourceImages:
              job.extraSourceImages ?? item.sourceImages.skip(1).toList(),
        );
      } else {
        setState(
            () => item.markFailed(job.errorMessage ?? 'extraction failed'));
        return;
      }
      setState(() {
        item.retryAt = null;
        item.processingSince = null;
        // Reaching here with every issue on seller_gstin (the server's own
        // "clean" count ignores it, same as DAS-71) means the server
        // already tried to auto-save this bill and the attempt itself
        // failed (a duplicate invoice number, a FEFO surprise) — the one
        // case left where a clean bill still waits on a human tap (DAS-79).
        item.status = result.issues.every((i) => i.field == 'seller_gstin')
            ? BatchItemStatus.pendingConfirm
            : BatchItemStatus.needsReview;
        item.recheckedThisReview = false;
        item.result = result;
        // jobId is deliberately left set: unsaved is not settled (DAS-79) —
        // _watching keeps asking in case our team saves it from here without
        // another tap on this phone.
      });
    } catch (_) {
      // Fetching the result failed, but the bill itself is finished. Leave it
      // in flight so the next round picks it up rather than calling a read
      // bill failed over one dropped request.
    }
  }

  /// A bill this phone had already filed under pendingConfirm/needsReview
  /// turned out to be saved on the next ask — an admin's correction, or a
  /// retried extraction saving a previously-failed clean bill, happened
  /// without any tap on this phone (DAS-79). `brief.saved` is the signal;
  /// refetch for the invoice id, the only thing still missing.
  Future<void> _applyAutoSave(BatchItem item, JobStatusBrief brief) async {
    try {
      final job = await ApiClient.instance.getExtractionJob(brief.jobId);
      if (!mounted || !job.isAlreadySaved) return;
      setState(() {
        item.jobId = null;
        item.retryAt = null;
        item.processingSince = null;
        item.status = BatchItemStatus.saved;
        item.savedInvoiceId = job.invoiceId;
        if (job.result != null) item.result = job.result;
      });
    } catch (_) {
      // Best-effort — jobId is untouched, so the next round (still watching)
      // tries again, same as any other dropped request here.
    }
  }
}
