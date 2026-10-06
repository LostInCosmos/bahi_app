import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/pending_photo_store.dart';
import '../../folders/data/folder_controller.dart';
import '../../folders/models/folder.dart';
import '../../folders/widgets/folder_widgets.dart';
import '../../invoice/models/invoice.dart';
import '../../invoice/presentation/gstin_confirm.dart';
import '../../invoice/presentation/invoice_detail_screen.dart';
import '../../invoice/presentation/review_screen.dart';
import '../data/batch_store.dart';
import '../models/batch_item.dart';
import '../widgets/batch_item_card.dart';
import '../widgets/capture_bottom_bar.dart';
import '../widgets/status_filter_bar.dart';
import '../models/status_filter.dart';
import '../widgets/capture_empty_state.dart';
import '../widgets/confirm_bill_dialog.dart';
import 'crop_screen.dart';

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
/// Nothing saves itself, ever. The backend's validation only catches
/// internal arithmetic inconsistency — it can't tell whether the vendor or
/// amount was read correctly. So even a clean result only reaches
/// `pendingConfirm`, a one-tap summary the user must confirm; anything with
/// an issue goes to `needsReview` and the full edit form.
class CaptureScreen extends StatefulWidget {
  final VoidCallback onBatchFinished;
  const CaptureScreen({super.key, required this.onBatchFinished});

  @override
  State<CaptureScreen> createState() => CaptureScreenState();
}

class CaptureScreenState extends State<CaptureScreen> {
  final List<BatchItem> _items = [];

  /// The shop's folders and where this screen is in them. Bills are shown
  /// folder by folder: a bill captured inside a folder is saved into it.
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
  final BatchStore? _store = BatchStore.forCurrentUser();

  // How long one bill may sit in pending/processing before this screen stops
  // waiting — shorter than the worker's own stale-job reclaim. It only stops
  // the spinner; the job is still reclaimed and retried server-side.
  // How long the server may be actively working on ONE attempt before the
  // card gives up. Queue time is excluded — see _timeOutStuckBills.
  static const _attemptTimeout = Duration(seconds: 120);
  // The server's reconciler re-queues a due retry on a 60s sweep, so pickup
  // can lag `retryAt` by up to that much.
  static const _retrySweepMargin = Duration(seconds: 60);

  bool _statusLoopRunning = false;

  bool get _hasUnresolved => _items.any((i) =>
      i.status == BatchItemStatus.needsReview ||
      i.status == BatchItemStatus.failed ||
      i.status == BatchItemStatus.pendingConfirm);
  bool get _allResolved => _items.isNotEmpty && _items.every((i) => i.status == BatchItemStatus.saved);

  @override
  void initState() {
    super.initState();
    _folders.addListener(_onFoldersChanged);
    _restoreBatch();
    refreshFolders();
  }

  @override
  void dispose() {
    _folders.removeListener(_onFoldersChanged);
    _folders.dispose();
    super.dispose();
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

  /// A disposed screen never writes: the next screen restores from the last
  /// save and redoes whatever this one hadn't recorded yet.
  Future<void> _persistBatch() async {
    if (!mounted) return;
    await _store?.save(_items);
  }

  Future<void> _restoreBatch() async {
    final store = _store;
    if (store == null) return;
    final restored = await store.load();
    if (restored.isEmpty || !mounted) return;
    setState(() => _items.addAll(restored));
    _reconcileItemFolders();

    final uploaded = restored.where((i) => i.isUploaded).toList();
    for (final item in uploaded) {
      // "ready" means a job was never submitted last session — start it.
      // "processing" with a jobId means one WAS submitted and may already be
      // done server-side — resume polling it rather than paying for another.
      if (item.status == BatchItemStatus.ready) {
        unawaited(_processOne(item));
      } else if (item.status == BatchItemStatus.processing && item.jobId != null) {
        unawaited(_processOne(item, resumeJobId: item.jobId));
      }
    }
    unawaited(_resumeUploads(restored.where((i) => !i.isUploaded).toList()));
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

  // ==================== capture & upload ====================

  /// Captures one or more photos for a single bill: after each crop, the user
  /// Several bills picked from the gallery at once (DAS-25).
  ///
  /// Each becomes an ordinary bill straight away — saved here, shown on
  /// the grid, waiting for its corners. No separate tray and no second
  /// kind of record, so folders, filtering, persistence and resume all
  /// work on them without knowing they arrived in a batch.
  ///
  /// Nothing is uploaded yet: the shopkeeper taps one, chooses its
  /// corners, and only then does it go to preprocessing.
  ///
  /// The camera stays one at a time. A camera cannot multi-select
  /// anyway, and someone photographing a single bill sees no change.
  Future<void> _pickManyFromGallery() async {
    final tenantId = _store?.tenantId;
    // Fixed now, as in _addPhoto: the folder you were in when you picked
    // is the one these bills belong to.
    final folderId = _folders.currentId;
    final files = await ImagePicker().pickMultiImage(imageQuality: 95);
    if (files.isEmpty || !mounted) return;

    // One file is the old single-bill flow, unchanged — straight to the
    // crop rather than onto the grid.
    if (files.length == 1) {
      await _addPickedFile(files.first, folderId);
      return;
    }

    final made = <BatchItem>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      // Written to the device as it is picked, before any cropping:
      // these bytes exist nowhere else.
      final photoId = tenantId == null ? null : await PendingPhotoStore.save(tenantId, bytes);
      made.add(BatchItem(
        label: 'Photo ${_items.length + made.length + 1}',
        pages: [
          BatchItemPage(
            photoId: photoId,
            memoryBytes: photoId == null ? bytes : null,
            filename: file.name,
            corners: const [],      // chosen when the shopkeeper crops it
            rotationDegrees: 0,
          )
        ],
      )
        ..status = BatchItemStatus.needsCrop
        ..folderId = folderId);
    }
    if (!mounted) return;
    setState(() => _items.addAll(made));
    // Recorded before anything else, so being killed keeps the stack.
    await _persistBatch();
  }

  /// One file from the gallery: the original single-bill flow, kept
  /// exactly as it was so nothing changes for someone uploading one
  /// bill. Crop first, then save, then upload.
  Future<void> _addPickedFile(XFile file, int? folderId) async {
    final tenantId = _store?.tenantId;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final crop = await Navigator.of(context).push<CropResult>(
      MaterialPageRoute(builder: (_) => CropScreen(imageBytes: bytes, pageNumber: 1)),
    );
    if (crop == null || crop.corners.length != 4 || !mounted) return;

    final photoId = tenantId == null ? null : await PendingPhotoStore.save(tenantId, bytes);
    final item = BatchItem(label: 'Photo ${_items.length + 1}', pages: [
      BatchItemPage(
        photoId: photoId,
        memoryBytes: photoId == null ? bytes : null,
        filename: file.name,
        corners: crop.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: crop.rotationDegrees,
      )
    ])
      ..folderId = folderId;
    if (!mounted) return;
    setState(() => _items.add(item));
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// Open the crop for a bill picked from the gallery and still waiting.
  ///
  /// The bill already exists and its photo is already on disk, so this
  /// only fills in the corners and starts the work — it must not write
  /// a second copy of the photo.
  Future<void> _cropPending(BatchItem item) async {
    final page = item.pages.first;
    final bytes = page.memoryBytes ??
        (page.photoId == null ? null : await PendingPhotoStore.read(page.photoId!));
    if (bytes == null) {
      setState(() {
        item.status = BatchItemStatus.failed;
        item.errorMessage = 'that photo is no longer on this device';
      });
      await _persistBatch();
      return;
    }
    if (!mounted) return;
    final crop = await Navigator.of(context).push<CropResult>(
      MaterialPageRoute(builder: (_) => CropScreen(imageBytes: bytes, pageNumber: 1)),
    );
    if (crop == null || crop.corners.length != 4 || !mounted) return;
    setState(() {
      item.pages[0] = BatchItemPage(
        photoId: page.photoId,
        memoryBytes: page.memoryBytes,
        filename: page.filename,
        corners: crop.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: crop.rotationDegrees,
      );
      item.status = BatchItemStatus.preparing;
    });
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// can finish or tap "+ Add another page" to add pages to the SAME bill.
  /// Each photo is written to the device as soon as its crop is confirmed.
  Future<void> _addPhoto(ImageSource source) async {
    final tenantId = _store?.tenantId;
    // Fixed now, not when the photo is done: the folder you were in when you
    // tapped capture is the one the bill belongs to.
    final folderId = _folders.currentId;
    final pages = <BatchItemPage>[];
    while (true) {
      final file = await ImagePicker().pickImage(source: source, imageQuality: 95);
      if (file == null) {
        if (pages.isEmpty) return;
        break; // cancelled a continuation page — keep what's already queued
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      final cropResult = await Navigator.of(context).push<CropResult>(
        MaterialPageRoute(builder: (_) => CropScreen(imageBytes: bytes, pageNumber: pages.length + 1)),
      );
      if (cropResult == null || cropResult.corners.length != 4) {
        if (pages.isEmpty) return;
        break;
      }

      final photoId = tenantId == null ? null : await PendingPhotoStore.save(tenantId, bytes);
      pages.add(BatchItemPage(
        photoId: photoId,
        // Kept in memory only if the disk write failed — this page then
        // can't survive a restart, exactly as before photos were saved.
        memoryBytes: photoId == null ? bytes : null,
        filename: file.name,
        corners: cropResult.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: cropResult.rotationDegrees,
      ));

      if (!cropResult.addAnotherPage) break;
    }
    if (!mounted) return;

    final item = BatchItem(label: 'Photo ${_items.length + 1}', pages: pages)..folderId = folderId;
    setState(() => _items.add(item));
    // Recorded before the upload starts, so a logout mid-upload still finds
    // this bill next time.
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// Uploads the bill's photos, then starts extraction without waiting for
  /// it — so the add buttons are free again immediately.
  Future<void> _uploadAndExtract(BatchItem item) async {
    await _uploadItem(item);
    if (mounted && item.status == BatchItemStatus.ready) {
      unawaited(_processOne(item));
    }
  }

  Future<void> _uploadItem(BatchItem item) async {
    setState(() => item.status = BatchItemStatus.preparing);
    final List<String> sourceImages;
    try {
      sourceImages = [];
      for (final page in item.pages) {
        final bytes = await page.loadBytes();
        if (bytes == null) {
          throw StateError('This photo is no longer on the device — please delete it and capture the bill again.');
        }
        sourceImages.add(await ApiClient.instance.preprocess(
          imageBytes: bytes,
          filename: page.filename,
          corners: page.corners,
          rotationDegrees: page.rotationDegrees,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.status = BatchItemStatus.failed;
        item.errorMessage = 'Upload failed: $e';
      });
      await _persistBatch();
      return;
    }
    // A screen disposed mid-upload leaves its photos on the device for the
    // next screen to upload again, rather than recording a result it can no
    // longer show.
    if (!mounted) return;

    final uploadedPages = item.pages;
    setState(() {
      item.sourceImages = sourceImages;
      item.pages = [];
      item.status = BatchItemStatus.ready;
      item.errorMessage = null;
    });
    // Save the server paths BEFORE deleting the local photos: a kill in
    // between leaves an orphan file (swept on next start), never a bill with
    // neither its photo nor its upload.
    await _persistBatch();
    for (final page in uploadedPages) {
      final id = page.photoId;
      if (id != null) await PendingPhotoStore.delete(id);
    }
  }

  void _removeItem(BatchItem item) {
    setState(() => _items.remove(item));
    _persistBatch();
    for (final page in item.pages) {
      final id = page.photoId;
      if (id != null) unawaited(PendingPhotoStore.delete(id));
    }
  }

  // ==================== extraction ====================

  /// Submits a bill for extraction, or adopts an id already in flight. Does
  /// not wait — [_statusLoop] watches every in-flight bill together.
  Future<void> _processOne(BatchItem item, {int? resumeJobId}) async {
    setState(() {
      item.status = BatchItemStatus.processing;
      item.processingSince = null;
    });
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
      }
      await _persistBatch();
      _ensureStatusLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.jobId = null;
        item.status = BatchItemStatus.failed;
        item.errorMessage = e.toString();
      });
      await _persistBatch();
    }
  }

  // ==================== watching ====================

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
      if (mounted && _watching.isNotEmpty) _ensureStatusLoop();
    }));
  }

  Map<int, BatchItem> get _watching => {
        for (final i in _items)
          if (i.jobId != null && i.status == BatchItemStatus.processing) i.jobId!: i,
      };

  Future<void> _statusLoop() async {
    var idleRounds = 0;
    while (mounted) {
      final watching = _watching;
      if (watching.isEmpty) {
        // Nothing to ask about. Costs no request at all; a few local ticks
        // then stop, and the next submission starts the loop again.
        if (++idleRounds > 3) return;
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      idleRounds = 0;

      // A bill the server is backing off on is not worth asking about until
      // it is due; it would only return "retrying" again.
      final due = watching.entries.where((e) => !e.value.isBackingOff(_retrySweepMargin)).toList();
      if (due.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }

      final JobStatusBatch batch;
      try {
        batch = await ApiClient.instance.jobStatuses(due.map((e) => e.key).toList());
      } catch (_) {
        // A dropped connection is expected on mobile and is NOT a failed
        // bill: the server holds the request open for ~25s, so a tunnel or a
        // wifi-to-cellular switch lands here routinely. Ask again — every
        // request re-reads current state, so nothing that happened while we
        // were away is lost.
        if (!mounted) return;
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      if (!mounted) return;

      for (final brief in batch.jobs) {
        final item = watching[brief.jobId];
        if (item != null) await _applyStatus(item, brief);
      }
      _timeOutStuckBills();
      await _persistBatch();
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
          // The clock starts when the server picks it up, not when the bill
          // was queued — see _timeOutStuckBills.
          item.processingSince ??= DateTime.now().toUtc();
        } else {
          // Back to queued: whatever the last attempt had done is void, and
          // a stale clock would time out a bill waiting its turn again.
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
      final ExtractionResult result;
      if (job.status == 'done') {
        result = job.result!;
      } else if (job.errorKind == 'structural_validation_failed') {
        result = ExtractionResult.blank(
          job.sourceImage ?? item.sourceImages.first,
          job.errorMessage ?? "Automatic extraction couldn't read this bill — please enter its details by hand.",
        );
      } else {
        setState(() {
          item.jobId = null;
          item.processingSince = null;
          item.status = BatchItemStatus.failed;
          item.errorMessage = job.errorMessage ?? 'extraction failed';
        });
        return;
      }
      setState(() {
        item.jobId = null;
        item.retryAt = null;
        item.processingSince = null;
        // Zero issues means the numbers are internally consistent, not that
        // they were read correctly — so this still waits on a human tap.
        item.status = result.issues.isEmpty ? BatchItemStatus.pendingConfirm : BatchItemStatus.needsReview;
        item.result = result;
      });
    } catch (_) {
      // Fetching the result failed, but the bill itself is finished. Leave it
      // in flight so the next round picks it up rather than calling a read
      // bill failed over one dropped request.
    }
  }

  /// A bill the server has actually been working on for too long.
  ///
  /// The clock runs from `processingSince`, NOT from submission. Queue time
  /// does not count: at three bills at a time, a bill twenty deep waits
  /// minutes before anyone looks at it, and the old timer called that failed
  /// — then Retry spent a fresh model call reproducing a result the server
  /// was already about to deliver.
  void _timeOutStuckBills() {
    final now = DateTime.now().toUtc();
    for (final item in _items) {
      final since = item.processingSince;
      if (since == null || now.difference(since) < _attemptTimeout) continue;
      setState(() {
        item.jobId = null;
        item.processingSince = null;
        item.status = BatchItemStatus.failed;
        item.errorMessage = 'This bill is taking longer than expected — please try again.';
      });
    }
  }

  /// Explicit "try again": always a fresh submission, never a resume.
  Future<void> _reprocessItem(BatchItem item) => _processOne(item);

  // ==================== review & save ====================

  Future<void> _openItem(BatchItem item) async {
    switch (item.status) {
      case BatchItemStatus.needsCrop:
        await _cropPending(item);
        return;
      case BatchItemStatus.saved:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => InvoiceDetailScreen(invoiceId: item.savedInvoiceId!)),
        );
        return;
      case BatchItemStatus.failed:
        await _offerRetry(item);
        return;
      case BatchItemStatus.pendingConfirm:
        final result = item.result!;
        // Look the supplier up while the confirm dialog is open, so tapping
        // Save can show the GSTIN step at once instead of after a round trip
        // — the same head start the review screen gets. Advisory only: the
        // save call re-decides.
        final hint = ApiClient.instance.lookupVendor(result.invoice);
        final action = await showConfirmBillDialog(context, item.label, result.invoice);
        if (!mounted) return;
        if (action == ConfirmBillAction.save) {
          await _confirmAndSave(item, result, hint: hint);
        } else if (action == ConfirmBillAction.edit) {
          await _openReview(item, result);
        }
        return;
      default:
        final result = item.result;
        if (result != null) await _openReview(item, result);
    }
  }

  Future<void> _offerRetry(BatchItem item) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.label),
        content: Text(item.errorMessage ?? 'Something went wrong processing this bill.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Retry')),
        ],
      ),
    );
    if (retry != true) return;
    // A save that failed is retried as a save. Re-extracting would spend an
    // LLM call to reproduce the result that has just failed to save.
    final result = item.result;
    if (item.failedAtSave && result != null) {
      await _confirmAndSave(item, result);
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
              item.status = hasErrors ? BatchItemStatus.needsReview : BatchItemStatus.pendingConfirm;
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

  /// Only reached from the one-tap confirm dialog — never automatic. A
  /// duplicate can still surface here even though extraction-time validation
  /// was clean, since the duplicate check only runs at save time.
  ///
  /// Asks for the supplier's GSTIN when the server needs a confirmation —
  /// before the round trip if the prefetched [hint] already says so, or
  /// after it if the hint was stale or never landed. Backing out of that
  /// question leaves the bill ready to confirm, not failed: nothing went
  /// wrong, the shopkeeper just has not answered yet.
  Future<void> _confirmAndSave(BatchItem item, ExtractionResult result, {Future<VendorHint?>? hint}) async {
    final meta = ExtractionMeta(
      sourceImage: item.sourceImages.first,
      extraSourceImages: item.sourceImages.skip(1).toList(),
      method: result.meta.method,
      reviewedByUser: true,
    );
    var gstinConfirmed = false;
    int? confirmedVendorId;

    Future<bool> ask(VendorHint question) async {
      // Loaded here rather than kept on every card: this is one bill, at the
      // moment it is being confirmed, and it is a cache hit in the normal
      // case. A missing picture just means the dialog shows none.
      Uint8List? photo;
      try {
        photo = await ApiClient.instance.fetchImage(item.sourceImages.first);
      } catch (_) {}
      if (!mounted) return false;
      final answer = await showGstinConfirmDialog(
        context, question,
        photo: photo,
        fallbackName: result.invoice.sellerName,
      );
      if (answer == null || !mounted) return false;
      result.invoice.sellerGstin = answer;
      gstinConfirmed = true;
      confirmedVendorId = question.vendorId;
      return true;
    }

    final prefetched = hint == null ? null : await hint;
    if (!mounted) return;
    if (prefetched != null && prefetched.needsConfirmation && !await ask(prefetched)) return;

    // At most a couple of rounds: the dialog only accepts a well-formed
    // GSTIN, which is all the server's "usable" check asks for.
    for (var round = 0; round < 3; round++) {
      try {
        final id = await ApiClient.instance.saveInvoice(
          result.invoice, meta,
          gstinConfirmed: gstinConfirmed,
          confirmedVendorId: confirmedVendorId,
          folderId: item.folderId,
        );
        if (!mounted) return;
        setState(() {
          item.status = BatchItemStatus.saved;
          item.savedInvoiceId = id;
          item.failedAtSave = false;
          item.errorMessage = null;
        });
        // Nothing was asked, so show that it landed.
        if (!gstinConfirmed) await showSavedTick(context);
        break;
      } on ApiException catch (e) {
        if (!mounted) return;
        final detail = e.detail;
        final kind = detail is Map ? detail['error'] : null;
        // Its folder was deleted since the bill was filed. Not worth failing
        // the save over: file it at home and say so.
        if (e.statusCode == 404 && e.message.contains('folder') && item.folderId != null) {
          setState(() => item.folderId = null);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('That folder no longer exists — saving to Home.')));
          continue;
        }
        if (kind == 'gstin_confirmation_required' || kind == 'gstin_required') {
          final asked = await ask(VendorHint(
            needsConfirmation: true,
            vendorKnown: detail['vendor_known'] as bool? ?? false,
            verified: false,
            vendorId: detail['vendor_id'] as int?,
            gstin: (detail['gstin'] ?? detail['read_gstin']) as String? ?? '',
            vendorName: (detail['seller_name'] as String?) ?? '',
          ));
          if (!asked) break;   // backed out: still ready to confirm
          continue;
        }
        if (kind == 'validation_failed') {
          final rawIssues = (detail['issues'] as List<dynamic>? ?? []);
          setState(() {
            item.status = BatchItemStatus.needsReview;
            item.result = ExtractionResult(
              invoice: result.invoice,
              meta: result.meta,
              issues: rawIssues.map((j) => ValidationIssue.fromJson(j as Map<String, dynamic>)).toList(),
            );
          });
        } else {
          setState(() {
            item.status = BatchItemStatus.failed;
            item.failedAtSave = true;
            item.errorMessage = e.message;
          });
        }
        break;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          item.status = BatchItemStatus.failed;
          item.failedAtSave = true;
          item.errorMessage = e.toString();
        });
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
    if (item.status == BatchItemStatus.saved && savedId != null) {
      try {
        await ApiClient.instance.moveInvoice(savedId, folderId: choice.folderId);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't move it: $e")));
        return;
      }
    }
    if (!mounted) return;
    setState(() => item.folderId = choice.folderId);
    await _persistBatch();
    unawaited(_folders.load()); // bill counts on the folder tiles
  }

  void _finish() {
    setState(() => _items.clear());
    _persistBatch();
    widget.onBatchFinished();
  }

  // ==================== layout ====================

  @override
  Widget build(BuildContext context) {
    final inFolder = _items.where((i) => i.folderId == _folders.currentId).toList();
    // Filtering composes with the folder rather than replacing it:
    // ticking a status narrows what is in this folder, it does not
    // leave it.
    final here = filterByStatus(inFolder, _statusFilter);
    final subfolders = _folders.children;
    final filtering = _statusFilter.isNotEmpty;
    return SafeArea(
      child: Column(
        children: [
          FolderBar(controller: _folders, onNewFolder: () => showNewFolderDialog(context, _folders)),
          if (_folders.loadError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
              child: Row(children: [
                Expanded(
                  child: Text("Couldn't load folders",
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                ),
                TextButton(onPressed: refreshFolders, child: const Text('Retry')),
              ]),
            ),
          if (_items.isNotEmpty || filtering)
            StatusFilterBar(
              items: inFolder,
              selected: _statusFilter,
              onChanged: (next) => setState(() => _statusFilter = next),
            ),
          Expanded(
            child: here.isEmpty && subfolders.isEmpty
                ? (filtering
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Nothing here matches those statuses'),
                        ),
                      )
                    : CaptureEmptyState(
                        onTakePhoto: () => _addPhoto(ImageSource.camera),
                        onPickFromGallery: _pickManyFromGallery,
                      ))
                : _buildGrid(here, subfolders),
          ),
          CaptureBottomBar(
            hasItems: _items.isNotEmpty,
            allResolved: _allResolved,
            hasUnresolved: _hasUnresolved,
            onTakePhoto: () => _addPhoto(ImageSource.camera),
            onPickFromGallery: _pickManyFromGallery,
            onFinish: _finish,
          ),
        ],
      ),
    );
  }

  /// Three across, so more bills fit than the old two-up grid; folder tiles sit
  /// above them.
  Widget _buildGrid(List<BatchItem> items, List<Folder> subfolders) {
    return CustomScrollView(
      slivers: [
        if (subfolders.isNotEmpty)
          folderTileGrid(folders: subfolders, onOpen: (f) => _folders.open(f.id), onMenu: _openFolderMenu),
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
                final item = items[i];
                return BatchItemCard(
                  key: ValueKey(item),
                  item: item,
                  onTap: () => _openItem(item),
                  onDelete: item.status != BatchItemStatus.processing && item.status != BatchItemStatus.saved
                      ? () => _removeItem(item)
                      : null,
                  onReprocess: item.isUploaded &&
                          item.status != BatchItemStatus.preparing &&
                          item.status != BatchItemStatus.processing
                      ? () => _reprocessItem(item)
                      : null,
                  // Not while an upload or extraction is in flight; its folder
                  // is read when it is saved, so it can be moved any time after.
                  onMove: item.status != BatchItemStatus.preparing && item.status != BatchItemStatus.processing
                      ? () => _moveItem(item)
                      : null,
                );
              },
              childCount: items.length,
            ),
          ),
        ),
      ],
    );
  }
}
