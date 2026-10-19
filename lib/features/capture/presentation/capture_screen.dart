import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../invoice/data/invoice_api.dart';
import '../data/capture_api.dart';
import '../../../core/utils/offset_2d.dart';
import '../../../core/utils/pending_photo_store.dart';
import '../../folders/data/folder_controller.dart';
import '../../folders/models/folder.dart';
import '../../folders/widgets/folder_widgets.dart';
import '../../invoice/models/invoice.dart';
import '../../invoice/models/job_status.dart';
import '../../invoice/widgets/saved_tick.dart';
import '../../invoice/presentation/invoice_detail_screen.dart';
import '../../invoice/presentation/review_screen.dart';
import '../data/batch_store.dart';
import '../models/batch_item.dart';
import '../models/bulk.dart';
import '../models/list_entry.dart';
import '../models/upload_summary.dart';
import '../widgets/batch_item_card.dart';
import '../widgets/capture_bottom_bar.dart';
import '../widgets/status_filter_bar.dart';
import '../models/bill_search.dart';
import '../models/status_filter.dart';
import '../models/pdf_pages.dart';
import '../widgets/capture_empty_state.dart';
import '../widgets/selection_bar.dart';
import '../widgets/upload_history.dart';
import '../widgets/confirm_bill_dialog.dart';
import '../widgets/unsave_dialog.dart';
import 'crop_screen.dart';

part 'capture_intake.dart';
part 'capture_selection.dart';
part 'capture_watching.dart';

/// Adobe-Scanner-style batch flow: add several bill photos (each gets its
/// corners set right after it's taken). Extraction for each bill starts on
/// its own the moment that bill finishes uploading — there's no separate
/// "Process" step, so a user can capture the next bill while the previous one
/// is still being read in the background.
///
/// Every photo is saved to the device before it is uploaded (see
/// PendingPhotoStore), and the batch itself is saved after every change (see
/// BatchStore). Logging out, the app being killed, or an app update partway
/// through a large batch therefore loses nothing: on the next start, saved
/// photos are uploaded and in-flight extractions resume polling.
///
/// A bill saves itself once it is clean (the backend's validation, which
/// only catches internal arithmetic inconsistency, found nothing) —
/// server-side, the moment that becomes true, with no tap and no wait
/// (DAS-79). `pendingConfirm` ("Not saved") is reached only when that save
/// was attempted and failed (a duplicate invoice number, a FEFO surprise,
/// a missing stored subtotal) or the shopkeeper deliberately unsaved a
/// bill — never as a routine step for an ordinary clean bill any more. A
/// one-tap summary lets them save (or edit) it from there; anything with a
/// real issue goes to `needsReview` and the full edit form.
class CaptureScreen extends StatefulWidget {
  final VoidCallback onBatchFinished;
  const CaptureScreen({super.key, required this.onBatchFinished});

  @override
  State<CaptureScreen> createState() => CaptureScreenState();
}

class CaptureScreenState extends State<CaptureScreen> with _Selection, _Intake, _Watching {
  @override
  final List<BatchItem> _items = [];

  @override
  final Set<int> _watchedRows = {};

  /// Whether this batch handed any bill over to the shop's list — so "Done"
  /// is still offered once every card of it has gone there (DAS-62).
  bool _batchHandedOver = false;

  /// The shop's folders and where this screen is in them. Bills are shown
  /// folder by folder: a bill captured inside a folder is saved into it.
  @override
  final FolderController _folders = FolderController();
  bool _foldersLoaded = false;

  /// Ticked statuses (DAS-26). Held on the State, so it survives
  /// switching tabs — the screen stays alive in the home IndexedStack —
  /// but not a restart, which is deliberate: coming back tomorrow to a
  /// grid silently hiding most of the shop's bills, with no memory of
  /// having set that, is worse than re-ticking a box.
  Set<String> _statusFilter = {};

  /// Fixed to the shop signed in when this screen was created, so work that
  /// finishes after a logout can't be saved under the next shop's batch.
  @override
  final BatchStore? _store = BatchStore.forCurrentUser();

  bool get _hasUnresolved => _items.any((i) =>
      i.status == BatchItemStatus.needsReview ||
      i.status == BatchItemStatus.failed ||
      i.status == BatchItemStatus.pendingConfirm);
  bool get _allResolved =>
      (_items.isNotEmpty || _batchHandedOver) &&
      _items.every((i) => i.status == BatchItemStatus.saved);

  @override
  void initState() {
    super.initState();
    _folders.addListener(_onFoldersChanged);
    _restoreBatch();
    refreshFolders();
  }

  @override
  void dispose() {
    _listRefresh?.cancel();
    _searchController.dispose();

    _retryLock?.cancel();
    _folders.removeListener(_onFoldersChanged);
    _folders.dispose();
    super.dispose();
  }

  Timer? _listRefresh;

  // The search box. Entirely on the phone: it filters the bills that are
  // loaded as letters are typed, and the list loads the rest while it is used.
  final TextEditingController _searchController = TextEditingController();
  String _query = ''; // normalised: trimmed, lower-cased; empty is no search

  // Retries are locked for a moment after each one. In a filtered list the
  // retried bill leaves the box at once and the list closes up, so the NEXT
  // bill is now under the same spot — a double tap, or ten quick taps in one
  // place, retried ten different bills ("it retried many"). A tap on a
  // different bill a second later is still immediate.
  Timer? _retryLock;
  static const _retryLockFor = Duration(milliseconds: 1200);

  /// Whether this tap may retry something; takes the lock if it may.
  bool _mayRetry() {
    if (_retryLock?.isActive ?? false) return false;
    _retryLock = Timer(_retryLockFor, () {});
    return true;
  }

  /// A bill has just entered or left Working — a retry began, or a read
  /// finished or failed: move the numbers now (one box down, the other up),
  /// rather than when the server is next asked. Only changes involving
  /// Working are made live; everything else waits for the server's own count.
  /// Bills with no job yet are not in the server's tally — the screen counts
  /// those itself — so they are not moved here.
  @override
  void _noteMove(BatchItem item, String? before) {
    if ((item.lastJobId ?? item.jobId) == null) return;
    final after = categoryOfItem(item);
    if (before == after || (before != 'working' && after != 'working')) return;
    _uploadHistory.currentState?.shiftCategory(item.folderId, before, after);
  }

  /// Ask the list for fresh numbers, once for a burst of finishing bills
  /// rather than once per bill.
  @override
  void _scheduleListRefresh() {
    if (_listRefresh?.isActive ?? false) return;
    _listRefresh = Timer(const Duration(milliseconds: 800), () {
      if (mounted) unawaited(_uploadHistory.currentState?.refresh());
    });
  }

  void _onFoldersChanged() {
    if (mounted) setState(() {});
  }

  /// Public so HomeScreen can reload folders when this tab is selected — a
  /// folder made or removed on the Purchases tab would otherwise not show here.
  Future<void> refreshFolders() async {
    await _folders.load();
    if (!mounted) return;
    _foldersLoaded = _foldersLoaded || _folders.loadError == null;
    _reconcileItemFolders();
  }

  /// A bill whose folder no longer exists (deleted on another device) goes
  /// home instead of failing its save. Only judged once the tree has actually
  /// loaded: being offline must not send every filed bill home.
  void _reconcileItemFolders() {
    if (!_foldersLoaded || _folders.loadError != null) return;
    var changed = false;
    for (final item in _items) {
      if (!_folders.tree.contains(item.folderId)) {
        item.folderId = null;
        changed = true;
      }
    }
    if (changed) {
      setState(() {});
      _persistBatch();
    }
  }

  // ==================== persistence ====================

  /// [batchState] as of the last write, so [_persistBatchIfChanged] can tell
  /// whether anything stored has moved since.
  List<Object>? _writtenState;

  /// A disposed screen never writes: the next screen restores from the last
  /// save and redoes whatever this one hadn't recorded yet.
  @override
  Future<void> _persistBatch() async {
    if (!mounted) return;
    _writtenState = batchState(_items);
    await _store?.save(_items);
  }

  /// Writes only if something stored has changed since the last write. For
  /// the status loop alone; every other caller has just changed something
  /// and writes unconditionally.
  @override
  Future<void> _persistBatchIfChanged() async {
    if (!listEquals(batchState(_items), _writtenState)) await _persistBatch();
  }

  Future<void> _restoreBatch() async {
    final store = _store;
    if (store == null) return;
    final restored = await store.load();
    if (restored.isEmpty || !mounted) return;
    // A bill the server finished last session is the shop list's now
    // (DAS-62): its card here could only be a stale copy — 25 such cards once
    // said "needs review" for bills discarded long before.
    final finished = restored.where((i) => i.isFinishedOnServer).toList();
    restored.removeWhere(finished.contains);
    for (final item in finished) {
      if (item.status != BatchItemStatus.saved) {
        _watchedRows.add((item.lastJobId ?? item.jobId)!);
      }
    }
    setState(() => _items.addAll(restored));
    if (finished.isNotEmpty) unawaited(_persistBatch());
    _reconcileItemFolders();

    final toUpload = <BatchItem>[];
    for (final item in restored) {
      switch (item.startupAction) {
        case StartupAction.process:
          unawaited(_processOne(item));
        case StartupAction.resumeJob:
          unawaited(_processOne(item, resumeJobId: item.jobId));
        case StartupAction.askServer:
          unawaited(_retryFailed(item));
        case StartupAction.uploadAgain:
          toUpload.add(item);
        case StartupAction.none:
          break;
      }
    }
    unawaited(_resumeUploads(toUpload));
    // A restored pendingConfirm/needsReview bill has nothing above asking
    // for it: `startupAction` is `none` for both, since nothing needs
    // (re-)submitting. Without this, a bill our team or a vendor
    // verification saves while this phone is simply sitting open, having
    // been launched before that happened, would not be watched for at all
    // (DAS-79) — only the next explicit recheck (tab reopen, pull) would
    // find it.
    _ensureStatusLoop();
  }

  /// Photos saved on the device last session that never finished uploading.
  /// One at a time, so a 50-bill backlog doesn't load 50 photos into memory
  /// and onto the network at once.
  Future<void> _resumeUploads(List<BatchItem> items) async {
    for (final item in items) {
      if (!mounted) return;
      await _uploadAndExtract(item);
    }
  }

  // ==================== removing & discarding ====================

  /// Throw a bill away.
  ///
  /// This used to drop it from THIS device only, which was invisible while
  /// the phone showed nothing but its own bills. Now that the shop's uploads
  /// are listed too, a local-only removal would be a cross that does
  /// nothing: the bill reappears from the server a moment later. So anything
  /// the server knows about is discarded there, and the row stays for our
  /// team with a "discarded" mark.
  Future<void> _removeItem(BatchItem item) async {
    if (item.status == BatchItemStatus.saved || item.savedInvoiceId != null) {
      final invoiceId = item.savedInvoiceId;
      return invoiceId == null
          ? _say(_savedNoId)
          : _unsave(invoiceId, item: item);
    }
    final jobId = item.jobId ?? item.lastJobId;
    if (jobId != null) {
      try {
        // One bill is a batch of one: there is no single-bill discard.
        final reply = await ApiClient.instance.bulkDiscard([jobId]);
        if (!reply.discarded.contains(jobId)) {
          throw 'it is saved or still being read';
        }
      } catch (e) {
        if (!mounted) return;
        // Left on screen deliberately: a bill that is still on the server
        // must keep its card, or the shopkeeper thinks it is gone.
        _say("Couldn't remove that bill: $e");
        return;
      }
    }
    if (!mounted) return;
    _dropLocal(item);
    unawaited(_uploadHistory.currentState?.refresh());
  }

  static const _savedNoId = 'This bill is saved. Open it to change it.';

  /// The ✕ on a SAVED bill: send it back to Not saved, asking whether its
  /// stock leaves inventory too. It is not thrown away from here — the bill
  /// comes back to be checked again — and the stock is the shopkeeper's call.
  ///
  /// Except for a bill our team is still looking at: its stock always goes
  /// back with it (the server does that whatever is sent), so there is nothing
  /// to ask, and the dialog says so. [underReview] comes from the shop's list
  /// when the caller has the row; otherwise it is read from the bill itself.
  Future<void> _unsave(int invoiceId,
      {BatchItem? item, bool? underReview}) async {
    underReview ??= await _isUnderReview(invoiceId);
    if (!mounted) return;
    final bool removeStock;
    if (underReview) {
      if (!await showUnsaveUnderReviewDialog(context) || !mounted) return;
      removeStock = true;
    } else {
      final choice = await showUnsaveDialog(context);
      if (choice == null || !mounted) return;
      removeStock = choice == UnsaveChoice.removeStock;
    }
    final bool removed;
    try {
      removed = await ApiClient.instance
          .unsaveInvoice(invoiceId, removeStock: removeStock);
    } on ApiException catch (e) {
      // Stock already sold, or no read to go back to: nothing changed.
      if (mounted) _say("Couldn't move it back: ${e.message}");
      return;
    } catch (e) {
      if (mounted) _say("Couldn't move it back: $e");
      return;
    }
    if (!mounted) return;
    // This phone's copy of a saved bill is finished with; the shop's list
    // shows the bill again, unsaved, once it is asked.
    if (item != null) _dropLocal(item);
    _say(removed
        ? 'Moved back to Not saved. Its stock was taken out of inventory.'
        : 'Moved back to Not saved. Its stock stays in inventory.');
    unawaited(_uploadHistory.currentState?.refresh());
    unawaited(_folders.load());
  }

  /// Whether our team is still looking at this saved bill. Asked of the server
  /// because this phone's own copy cannot know; a failed question reads as
  /// "no", which only means the shopkeeper is asked about the stock as before
  /// (the server decides either way).
  Future<bool> _isUnderReview(int invoiceId) async {
    try {
      return (await ApiClient.instance.getInvoiceDetail(invoiceId))
          .isUnderReview;
    } catch (_) {
      return false;
    }
  }

  /// The ✕ on a processed bill from the shop's list (failed ones included;
  /// bills still being read have none). A saved bill is sent back to Check &
  /// save instead, after asking about its stock. Otherwise it goes at once and
  /// comes back if the server refuses, exactly as a bulk discard does.
  Future<void> _discardUpload(UploadSummary upload) async {
    final category = uploadCategory(upload);
    if (category == 'saved') {
      final invoiceId = upload.invoiceId;
      return invoiceId == null
          ? _say(_savedNoId)
          : _unsave(invoiceId, underReview: upload.isUnderReview);
    }
    final history = _uploadHistory.currentState;
    history?.forget([upload.jobId]);
    _watchedRows.remove(upload.jobId);
    try {
      final reply = await ApiClient.instance.bulkDiscard([upload.jobId]);
      if (!reply.discarded.contains(upload.jobId)) {
        throw 'the server would not discard it';
      }
    } catch (e) {
      history?.restore([upload]);
      if (mounted) _say("Couldn't remove that bill: $e");
      return;
    }
    if (mounted) unawaited(_folders.load());
  }

  /// The shop's list now shows these bills in the box their cards are in, so
  /// the cards go and the list's rows are the only ones (DAS-62). One that is
  /// not saved is still watched by its job — see [_watchedRows].
  void _handOver(List<BatchItem> items) {
    final gone = items.where(_items.contains).toList();
    if (gone.isEmpty) return;
    for (final item in gone) {
      if (item.status != BatchItemStatus.saved) {
        _watchedRows.add((item.lastJobId ?? item.jobId)!);
      }
    }
    setState(() {
      _items.removeWhere(gone.contains);
      _batchHandedOver = true;
    });
    _persistBatch();
    _ensureStatusLoop();
  }

  /// Forget a bill on THIS device: its card, its saved state and its photos.
  /// Nothing about the server — callers settle that first.
  @override
  void _dropLocal(BatchItem item) {
    setState(() => _items.remove(item));
    _persistBatch();
    for (final page in item.pages) {
      final id = page.photoId;
      if (id != null) unawaited(PendingPhotoStore.delete(id));
    }
  }

  @override
  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ==================== review, save & retry ====================

  /// Explicit "try again". A bill that failed is retried the way the dialog
  /// retries it — a failed save as a save, a failed upload as an upload — and
  /// any other is a fresh read.
  Future<void> _reprocessItem(BatchItem item) async {
    if (!_mayRetry()) return;
    return item.status == BatchItemStatus.failed
        ? _retryFailed(item)
        : _processOne(item);
  }

  Future<void> _openItem(BatchItem item) async {
    switch (item.status) {
      case BatchItemStatus.needsCrop:
        await _cropPending(item);
        return;
      case BatchItemStatus.saved:
        Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) =>
                  InvoiceDetailScreen(invoiceId: item.savedInvoiceId!)),
        );
        return;
      case BatchItemStatus.failed:
        await _offerRetry(item);
        return;
      case BatchItemStatus.pendingConfirm:
        final result = item.result!;
        final action =
            await showConfirmBillDialog(context, item.label, result.invoice);
        if (!mounted) return;
        if (action == ConfirmBillAction.save) {
          await _saveBill(item);
        } else if (action == ConfirmBillAction.edit) {
          await _openReview(item, result);
        }
        return;
      case BatchItemStatus.needsReview:
        // A flagged bill is with our team (DAS-71): the shopkeeper may save
        // what was read, but is not asked to correct it, so there is no Edit.
        final result = item.result;
        if (result == null) {
          _say('That bill has not finished being read yet.');
          return;
        }
        final action = await showConfirmBillDialog(
            context, item.label, result.invoice,
            allowEdit: false);
        if (!mounted) return;
        if (action == ConfirmBillAction.save) await _saveBill(item);
        return;
      default:
        final result = item.result;
        if (result != null) await _openReview(item, result);
    }
  }

  Future<bool> _askRetry(String title, String? message) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message ?? 'Something went wrong processing this bill.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Close')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Retry')),
        ],
      ),
    );
    return retry == true;
  }

  Future<void> _offerRetry(BatchItem item) async {
    if (!await _askRetry(item.label, item.errorMessage)) return;
    await _retryFailed(item);
  }

  Future<void> _retryFailed(BatchItem item) async {
    // This phone gave up while the server carried on: ask the server what
    // became of the job before paying for another read. If it finished, the
    // watch loop folds the result in; if it truly failed, it says so.
    if (item.failedByTimeout) {
      final before = categoryOfItem(item);
      setState(() {
        item.jobId = item.lastJobId;
        item.status = BatchItemStatus.processing;
        item.processingSince = null;
        item.errorMessage = null;
      });
      _noteMove(item, before);
      await _persistBatch();
      _ensureStatusLoop();
      return;
    }
    // A save that failed is retried as a save. Re-extracting would spend an
    // LLM call to reproduce the result that has just failed to save.
    if (item.failedAtSave && (item.jobId ?? item.lastJobId) != null) {
      await _saveBill(item);
      return;
    }
    // A failed upload has nothing on the server to extract yet — redo the
    // upload, and let it start extraction itself once it succeeds.
    await (item.isUploaded ? _processOne(item) : _uploadAndExtract(item));
  }

  Future<void> _openReview(BatchItem item, ExtractionResult result) async {
    final savedId = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          result: result,
          folderId: item.folderId,
          onRevalidated: (updatedResult, hasErrors) {
            setState(() {
              item.result = updatedResult;
              item.status = hasErrors
                  ? BatchItemStatus.needsReview
                  : BatchItemStatus.pendingConfirm;
              item.recheckedThisReview = false;
            });
            _persistBatch();
          },
        ),
      ),
    );
    if (savedId != null && mounted) {
      setState(() {
        item.status = BatchItemStatus.saved;
        item.savedInvoiceId = savedId;
      });
      await _persistBatch();
    }
  }

  /// Saves what the server read, by job: the phone sends no values (DAS-71), so
  /// it cannot overwrite a correction from our team, and a clean bill and a
  /// flagged one save the same way. Only reached from the confirm dialog —
  /// never automatic. Stock goes in at once; our team corrects any difference
  /// later. Nothing is asked about the supplier's GSTIN: that is theirs to check.
  Future<void> _saveBill(BatchItem item) async {
    final jobId = item.jobId ?? item.lastJobId;
    if (jobId == null) {
      setState(() =>
          item.markFailed('This bill has not been read yet.', atSave: true));
      await _persistBatch();
      return;
    }
    // Twice at most: the second try is for a folder that was deleted since
    // the bill was filed.
    for (var round = 0; round < 2; round++) {
      try {
        final saved =
            await ApiClient.instance.saveJob(jobId, folderId: item.folderId);
        if (!mounted) return;
        setState(() {
          item.status = BatchItemStatus.saved;
          item.savedInvoiceId = saved.invoiceId;
          item.failedAtSave = false;
          item.errorMessage = null;
        });
        // The shop's row turns Saved, and the card hands over to it.
        _scheduleListRefresh();
        await showSavedTick(context);
        break;
      } on ApiException catch (e) {
        if (!mounted) return;
        // Its folder was deleted since the bill was filed. Not worth failing
        // the save over: file it at home and say so.
        if (e.statusCode == 404 &&
            e.message.contains('folder') &&
            item.folderId != null) {
          setState(() => item.folderId = null);
          _say('That folder no longer exists — saving to Home.');
          continue;
        }
        if (e.statusCode == 409) {
          // Saved already (from another phone, or a tap that went through).
          // Not a failure: the list shows it as saved once it is asked.
          _say(e.message);
          unawaited(_uploadHistory.currentState?.refresh());
          break;
        }
        if (e.statusCode == 422) {
          _say('That bill has not finished being read yet.');
          break;
        }
        setState(() => item.markFailed(e.message, atSave: true));
        break;
      } catch (e) {
        if (!mounted) return;
        setState(() => item.markFailed(e.toString(), atSave: true));
        break;
      }
    }
    await _persistBatch();
  }

  // ==================== folders ====================

  Future<void> _openFolderMenu(Folder folder) => showFolderActions(
        context,
        _folders,
        folder,
        // The server moved the saved bills; bills still in this batch are only
        // known to this phone, so they move up a level here.
        onDeleted: (deleted, _) {
          for (final item in _items.where((i) => i.folderId == deleted.id)) {
            item.folderId = deleted.parentId;
          }
          setState(() {});
          _persistBatch();
        },
      );

  /// Moving an unsaved bill only changes where it will be saved; moving a
  /// saved one is a server call, and the card follows only if that succeeds.
  Future<void> _moveItem(BatchItem item) async {
    final choice = await showFolderPicker(
      context,
      tree: _folders.tree,
      title: 'Move ${item.label} to…',
      currentId: item.folderId,
    );
    if (choice == null || choice.folderId == item.folderId || !mounted) return;
    final savedId = item.savedInvoiceId;
    final jobId = item.jobId ?? item.lastJobId;
    try {
      // One bill is a batch of one: there is no separate single-bill move.
      final saved = item.status == BatchItemStatus.saved && savedId != null;
      if (saved || jobId != null) {
        final reply = await ApiClient.instance.bulkMove(
          jobIds: saved ? const [] : [jobId!],
          invoiceIds: saved ? [savedId] : const [],
          folderId: choice.folderId,
        );
        final moved = saved
            ? reply.movedInvoices.contains(savedId)
            : reply.movedJobs.contains(jobId);
        if (!moved) throw 'it is saved, discarded or no longer in this shop';
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't move it: $e")));
      return;
    }
    if (!mounted) return;
    setState(() => item.folderId = choice.folderId);
    await _persistBatch();
    unawaited(_folders.load()); // bill counts on the folder tiles
  }

  void _finish() {
    setState(() {
      _items.clear();
      _batchHandedOver = false;
    });
    _persistBatch();
    widget.onBatchFinished();
  }

  // ==================== layout ====================

  @override
  Widget build(BuildContext context) {
    final inFolder =
        _items.where((i) => i.folderId == _folders.currentId).toList();
    // Filtering composes with the folder rather than replacing it:
    // ticking a status narrows what is in this folder, it does not
    // leave it.
    final byStatus = filterByStatus(inFolder, _statusFilter);
    final here = _query.isEmpty
        ? byStatus
        : byStatus.where((i) => i.matchesSearch(_query)).toList();
    final subfolders = _folders.children;
    final filtering = _statusFilter.isNotEmpty || _query.isNotEmpty;
    return SafeArea(
      child: Column(
        children: [
          FolderBar(
              controller: _folders,
              onNewFolder: () => showNewFolderDialog(context, _folders)),
          if (_folders.loadError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
              child: Row(children: [
                Expanded(
                  child: Text("Couldn't load folders",
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12)),
                ),
                TextButton(
                    onPressed: refreshFolders, child: const Text('Retry')),
              ]),
            ),
          if (_pdfProgress != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.m, vertical: Spacing.s),
              child: Align(
                  alignment: Alignment.centerLeft, child: Text(_pdfProgress!)),
            ),
          // Search by shop or invoice number. Shown with the status boxes, since
          // both are about narrowing a list that is there.
          if (_items.isNotEmpty ||
              filtering ||
              _visible.isNotEmpty ||
              _choosing)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.m, Spacing.xs, Spacing.m, 0),
              child: TextField(
                key: const ValueKey('bill-search'),
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: (typed) =>
                    setState(() => _query = normaliseSearch(typed)),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search by shop or invoice number',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('bill-search-clear'),
                          icon: const Icon(Icons.close_rounded, size: 18),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.card)),
                ),
              ),
            ),
          // Shown whenever there is anything to filter — which on a freshly
          // signed-in phone means the shop's bills, not this device's. It
          // used to be gated on this device's bills alone, so exactly the
          // phone with the longest history had no way to filter it.
          if (_items.isNotEmpty ||
              filtering ||
              _visible.isNotEmpty ||
              _choosing)
            Row(
              children: [
                Expanded(
                  child: StatusFilterBar(
                    items: inFolder,
                    counts: _countsAcrossList(inFolder),
                    selected: _statusFilter,
                    onChanged: (next) => setState(() => _statusFilter = next),
                  ),
                ),
                TextButton(
                  onPressed: _choosing
                      ? _stopChoosing
                      : () => setState(() => _choosing = true),
                  child: Text(_choosing ? 'Done' : 'Select'),
                ),
              ],
            ),
          Expanded(
            // Always the scroll view: the shop's bills live inside it, so
            // short-circuiting to an empty state would hide them.
            child: _buildGrid(
              here,
              subfolders,
              // Not while more bills are still to be fetched: the ones that
              // match may be on a page that has not loaded.
              empty: here.isEmpty &&
                  subfolders.isEmpty &&
                  _visible.isEmpty &&
                  _listSettled &&
                  !_visibleMore,
              filtering: filtering,
            ),
          ),
          if (_moving != null) _MoveStrip(_moving!),
          if (_choosing)
            SelectionBar(
              count: _chosenEntries().length,
              more: _visibleMore,
              busy: _bulkBusy,
              onSelectAll: _selectAll,
              onMove: _moveChosen,
              onDiscard: _discardChosen,
            )
          else
            CaptureBottomBar(
              // Bills on screen at all, not just cards this phone holds — those
              // go to the shop's list once read (DAS-62), and without this a
              // full list had no way to add another.
              hasItems: _items.isNotEmpty || _visible.isNotEmpty,
              allResolved: _allResolved,
              hasUnresolved: _hasUnresolved,
              onTakePhoto: () => _addPhoto(ImageSource.camera),
              onPickFromGallery: _pickManyFromGallery,
              onPickPdf: _pickPdf,
              onFinish: _finish,
            ),
        ],
      ),
    );
  }

  /// What each box would show if ticked: this device's bills in the folder
  /// plus the shop's, so the number on a box means the same as the list.
  Map<String, int> _countsAcrossList(List<BatchItem> inFolder) {
    // When the list's numbers are the server's whole-shop tally, they already
    // include every bill this phone has sent, so only the ones that have not
    // reached the server are added; otherwise the phone's bills are added to
    // the shop's bills that are not on it.
    final covered =
        _uploadHistory.currentState?.countsCoverDeviceBills ?? false;
    final counts = {
      ...statusCounts(covered
          ? inFolder.where((i) => (i.jobId ?? i.lastJobId) == null).toList()
          : inFolder),
    };
    _serverCounts.forEach((key, n) => counts[key] = (counts[key] ?? 0) + n);
    return counts;
  }

  @override
  final GlobalKey<UploadHistoryState> _uploadHistory =
      GlobalKey<UploadHistoryState>();

  // ---- what each folder tile says ----
  //
  // Counted here, from the bills this screen holds, rather than asked of the
  // server: the server's number counts saved bills only (a folder of 327
  // unread-or-unsaved bills said "5 bills"), and it only changes when the
  // folders are fetched again — long after the bills visibly moved.
  Map<int?, int> _folderTotals = const {};

  void _onFolderTotals(Map<int?, int> totals) {
    if (!mounted) return;
    setState(() => _folderTotals = totals);
  }

  /// Every bill in [id] and the folders beneath it, plus this phone's own
  /// bills that have not reached the server yet and so are in no list.
  int _billsIn(int id) {
    final ids = <int>{id};
    final queue = [id];
    while (queue.isNotEmpty) {
      for (final child in _folders.tree.childrenOf(queue.removeLast())) {
        if (ids.add(child.id)) queue.add(child.id);
      }
    }
    final onServer = ids.fold(0, (n, f) => n + (_folderTotals[f] ?? 0));
    final onlyHere = _items
        .where(
            (i) => (i.jobId ?? i.lastJobId) == null && ids.contains(i.folderId))
        .length;
    return onServer + onlyHere;
  }

  String _folderSubtitle(Folder folder) => folderSubtitle(
        // Until the list has answered, the server's own count is the best
        // there is.
        bills: _listSettled ? _billsIn(folder.id) : folder.billCount,
        folders: _folders.tree.childrenOf(folder.id).length,
      );

  /// Open a bill the SHOP has but this DEVICE does not, through the same
  /// confirm / review / save flow as any other card.
  ///
  /// It is wrapped in a BatchItem so that flow works on it unchanged — but
  /// the item is NOT added to the grid. It used to be, and that was the
  /// bug: the device's own bills draw above the shop's list, so every bill
  /// you tapped jumped to the top and stayed there, and the list stopped
  /// being in upload order. A bill's place is where it was uploaded, and
  /// looking at it must not move it.
  Future<void> _adoptAndOpen(UploadSummary upload) async {
    final existing =
        _items.where((i) => i.sourceImages.contains(upload.sourceImage));
    if (existing.isNotEmpty) {
      await _openItem(existing.first);
      return;
    }

    if (uploadCategory(upload) == 'failed') {
      await _offerRetryForUpload(upload);
      return;
    }

    final item = BatchItem(label: 'Bill', pages: [])
      ..sourceImages = [upload.sourceImage]
      ..jobId = upload.jobId
      ..lastJobId = upload.jobId // what Save is addressed to
      ..folderId = upload.folderId
      ..savedInvoiceId = upload.invoiceId
      ..status = BatchItemStatus.processing; // until the result is in

    try {
      // The result is fetched for this one bill only — the list itself
      // deliberately carries none of them.
      final job = await ApiClient.instance.getExtractionJob(upload.jobId);
      final result = job.result;
      if (result == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('That bill has not finished being read yet.')),
        );
        return;
      }
      item
        ..result = result
        ..jobId = null // it is finished; nothing to poll
        ..status = upload.invoiceId != null
            ? BatchItemStatus.saved
            : (uploadCategory(upload) == 'review'
                ? BatchItemStatus.needsReview
                : BatchItemStatus.pendingConfirm)
        ..recheckedThisReview = false;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open that bill: $e")),
      );
      return;
    }

    if (!mounted) return;
    await _openItem(item);
    if (!mounted) return;
    // Quietly, not reload(): that empties the list and refetches, which
    // would throw away the scroll position you are coming back to. A bill
    // saved in there shows as Saved; nothing moves.
    unawaited(_uploadHistory.currentState?.refresh());
  }

  /// A bill that FAILED, from the shop's list rather than this phone.
  ///
  /// Tapping one used to say "that bill has not finished being read yet" —
  /// untrue, and with no way to try again. It now says why it failed and
  /// offers Retry. A retry joins this phone's own bills so the status loop
  /// watches it; it keeps its place in the list, which is its upload order.
  Future<void> _offerRetryForUpload(UploadSummary upload) async {
    String? why;
    try {
      why = (await ApiClient.instance.getExtractionJob(upload.jobId))
          .errorMessage;
    } catch (_) {
      // Not worth refusing a retry over: the dialog just says less.
    }
    if (!mounted) return;
    if (!await _askRetry('Bill', why)) return;
    await _retryUpload(upload, why: why);
  }

  /// Read a bill from the shop's list again. It joins this phone's own bills
  /// so the status loop watches it, and keeps its place — its upload order.
  /// Works on any bill that is not being read: one that failed, or one whose
  /// result needs a second look.
  Future<void> _retryUpload(UploadSummary upload, {String? why}) async {
    if (!_mayRetry()) return;
    // The server counts this bill in the box it is in now; it is about to be
    // read again, so one moves from that box to Working at once.
    _uploadHistory.currentState
        ?.shiftCategory(upload.folderId, uploadCategory(upload), 'working');
    final item = BatchItem(label: 'Bill', pages: [])
      ..sourceImages = [upload.sourceImage]
      ..lastJobId = upload.jobId
      ..folderId = upload.folderId
      ..status = BatchItemStatus.processing
      ..errorMessage = why;
    setState(() => _items.add(item));
    await _processOne(item);
    unawaited(_uploadHistory.currentState?.refresh());
  }

  /// ONE list: this device's bills and the shop's, three across, in the order
  /// they were uploaded. Folder tiles sit above them.
  Widget _buildGrid(List<BatchItem> items, List<Folder> subfolders,
      {required bool empty, required bool filtering}) {
    // This device's bills as cards on the shared list. Each carries the place
    // it sits — its upload order — so it lands among the shop's bills
    // rather than above them all.
    final localEntries = [
      for (var i = 0; i < items.length; i++)
        () {
          final item = items[i];
          final id = _idOf(item);
          return ListEntry(
            id: id,
            sortKey: localSortKey(item, _items.indexOf(item)),
            item: item,
            card: BatchItemCard(
              key: ValueKey(item),
              item: item,
              choosing: _choosing,
              chosen: _chosen.contains(id),
              onTap: () => _choosing ? _toggleChosen(id) : _openItem(item),
              // While choosing, the per-bill controls go: acting on one bill
              // by its own button and on a selection at once would be two
              // ways to do the same thing on one screen.
              // Processed bills only — failed ones included, none still being
              // read.
              onDelete: !_choosing && !matchesStatusFilter(item, 'working')
                  ? () => _removeItem(item)
                  : null,
              onReprocess: item.canReprocess(choosing: _choosing)
                  ? () => _reprocessItem(item)
                  : null,
              onRecheckNeedsReview: _recheckNeedsReview,
              // Not while an upload or extraction is in flight; its folder
              // is read when it is saved, so it can be moved any time after.
              onMove: !_choosing &&
                      item.status != BatchItemStatus.preparing &&
                      item.status != BatchItemStatus.processing
                  ? () => _moveItem(item)
                  : null,
            ),
          );
        }(),
    ];

    return RefreshIndicator(
      // An explicit pull means "give me the truth now" (DAS-76): a full
      // resync of the shop's list — reload(), not refresh(), since refresh()
      // only touches the newest page — plus every locally-held bill still
      // sitting in needsReview, which reload() alone would not touch (its
      // card is drawn from the local copy, not the shop list; see
      // UploadHistory's own doc comment on why).
      onRefresh: () => Future.wait([
        _uploadHistory.currentState?.reload() ?? Future.value(),
        recheckNeedsReview(),
      ]),
      child: CustomScrollView(
        slivers: [
          // Shown only when the screen is empty of EVERYTHING — this
          // device's bills and the shop's alike, and only once the shop's
          // list has actually answered. It used to depend on the local grid
          // alone, so a new phone greeted a shop of 214 bills with an advert
          // for the feature it was already using.
          if (empty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: filtering
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_query.isNotEmpty
                            ? 'No bill matches that search'
                            : 'Nothing here matches those statuses'),
                      ),
                    )
                  : CaptureEmptyState(
                      onTakePhoto: () => _addPhoto(ImageSource.camera),
                      onPickFromGallery: _pickManyFromGallery,
                      onPickPdf: _pickPdf,
                    ),
            ),
          if (subfolders.isNotEmpty)
            folderTileGrid(
              folders: subfolders,
              onOpen: (f) => _folders.open(f.id),
              onMenu: _openFolderMenu,
              subtitleOf: _folderSubtitle,
            ),
          UploadHistory(
            key: _uploadHistory,
            onFolderTotals: _onFolderTotals,
            onHandOver: _handOver,
            query: _query,
            onRetry: _retryUpload,
            onDelete: _discardUpload,
            localItems: _items,
            localEntries: localEntries,
            folderId: _folders.currentId,
            selected: _statusFilter,
            choosing: _choosing,
            chosen: _chosen,
            onToggle: _toggleChosen,
            onOpen: _adoptAndOpen,
            onEntries: _onEntries,
          ),
        ],
      ),
    );
  }
}
