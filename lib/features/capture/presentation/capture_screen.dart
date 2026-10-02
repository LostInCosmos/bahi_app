import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/pending_photo_store.dart';
import '../../../core/utils/poll.dart';
import '../../invoice/models/invoice.dart';
import '../../invoice/presentation/invoice_detail_screen.dart';
import '../../invoice/presentation/review_screen.dart';
import '../data/batch_store.dart';
import '../models/batch_item.dart';
import '../widgets/batch_item_card.dart';
import '../widgets/capture_bottom_bar.dart';
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
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final List<BatchItem> _items = [];

  /// Fixed to the shop signed in when this screen was created, so work that
  /// finishes after a logout can't be saved under the next shop's batch.
  final BatchStore? _store = BatchStore.forCurrentUser();

  // How long one bill may sit in pending/processing before this screen stops
  // waiting — shorter than the worker's own stale-job reclaim. It only stops
  // the spinner; the job is still reclaimed and retried server-side.
  static const _pollTimeout = Duration(seconds: 120);
  static const _pollInterval = Duration(seconds: 2);

  bool get _hasUnresolved => _items.any((i) =>
      i.status == BatchItemStatus.needsReview ||
      i.status == BatchItemStatus.failed ||
      i.status == BatchItemStatus.pendingConfirm);
  bool get _allResolved => _items.isNotEmpty && _items.every((i) => i.status == BatchItemStatus.saved);

  @override
  void initState() {
    super.initState();
    _restoreBatch();
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
    // Resuming extraction must not wait on pictures.
    unawaited(_loadThumbnails(uploaded));
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

  /// Fills in each restored card's picture — from the device cache in the
  /// usual case, otherwise fetched in parallel rather than one after another.
  Future<void> _loadThumbnails(List<BatchItem> items) async {
    await Future.wait(items.map((item) async {
      try {
        final bytes = await ApiClient.instance.fetchImage(item.sourceImages.first);
        if (!mounted) return;
        setState(() => item.correctedBytes = bytes);
      } catch (_) {
        // The bill is still usable — only its picture is missing, so the card
        // has to say so rather than spin. One failure must not stop the rest.
        if (!mounted) return;
        setState(() => item.thumbnailFailed = true);
      }
    }));
  }

  // ==================== capture & upload ====================

  /// Captures one or more photos for a single bill: after each crop, the user
  /// can finish or tap "+ Add another page" to add pages to the SAME bill.
  /// Each photo is written to the device as soon as its crop is confirmed.
  Future<void> _addPhoto(ImageSource source) async {
    final tenantId = _store?.tenantId;
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

    final item = BatchItem(label: 'Photo ${_items.length + 1}', pages: pages);
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

    // The thumbnail is separate from the upload: failing to download it must
    // not send an uploaded bill back to re-uploading.
    try {
      final corrected = await ApiClient.instance.fetchImage(sourceImages.first);
      if (mounted) setState(() => item.correctedBytes = corrected);
    } catch (_) {
      if (mounted) setState(() => item.thumbnailFailed = true);
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

  /// Submits (or, given [resumeJobId], resumes polling) an extraction job and
  /// waits for it. Extraction runs in a backend worker, so this is a
  /// submit-then-poll loop rather than one long request.
  Future<void> _processOne(BatchItem item, {int? resumeJobId}) async {
    setState(() => item.status = BatchItemStatus.processing);
    try {
      int jobId;
      if (resumeJobId != null) {
        jobId = resumeJobId;
      } else if (item.lastJobId != null) {
        // Not this item's first attempt — reuse its existing row rather than
        // creating a separate one on every retry.
        jobId = await ApiClient.instance.retryExtraction(item.lastJobId!);
        item.jobId = jobId;
        await _persistBatch();
      } else {
        jobId = await ApiClient.instance.submitExtraction(
          item.sourceImages.first,
          extraSourceImages: item.sourceImages.skip(1).toList(),
        );
        item.jobId = jobId;
        item.lastJobId = jobId;
        await _persistBatch();
      }

      final job = await pollUntilTerminal<ExtractionJob>(
        fetch: () => ApiClient.instance.getExtractionJob(jobId),
        isTerminal: (j) => j.status == 'done' || j.status == 'failed',
        interval: _pollInterval,
        timeout: _pollTimeout,
      );
      final ExtractionResult result;
      if (job.status == 'done') {
        result = job.result!;
      } else if (job.errorKind == 'structural_validation_failed') {
        result = ExtractionResult.blank(
          job.sourceImage ?? item.sourceImages.first,
          job.errorMessage ?? "Automatic extraction couldn't read this bill — please enter its details by hand.",
        );
      } else {
        throw ApiException(502, job.errorMessage ?? 'extraction failed');
      }

      if (!mounted) return;
      setState(() {
        item.jobId = null;
        // Zero issues means the numbers are internally consistent, not that
        // they were read correctly — so this still waits on a human tap.
        item.status = result.issues.isEmpty ? BatchItemStatus.pendingConfirm : BatchItemStatus.needsReview;
        item.result = result;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        item.jobId = null;
        item.status = BatchItemStatus.failed;
        item.errorMessage = 'This bill is taking longer than expected — please try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.jobId = null;
        item.status = BatchItemStatus.failed;
        item.errorMessage = e.toString();
      });
    }
    await _persistBatch();
  }

  /// Explicit "try again": always a fresh submission, never a resume.
  Future<void> _reprocessItem(BatchItem item) => _processOne(item);

  // ==================== review & save ====================

  Future<void> _openItem(BatchItem item) async {
    switch (item.status) {
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
        final action = await showConfirmBillDialog(context, item.label, result.invoice);
        if (!mounted) return;
        if (action == ConfirmBillAction.save) {
          await _confirmAndSave(item, result);
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
    // A failed upload has nothing on the server to extract yet — redo the
    // upload, and let it start extraction itself once it succeeds.
    await (item.isUploaded ? _processOne(item) : _uploadAndExtract(item));
  }

  Future<void> _openReview(BatchItem item, ExtractionResult result) async {
    final savedId = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          result: result,
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
  Future<void> _confirmAndSave(BatchItem item, ExtractionResult result) async {
    final meta = ExtractionMeta(
      sourceImage: item.sourceImages.first,
      extraSourceImages: item.sourceImages.skip(1).toList(),
      method: result.meta.method,
      reviewedByUser: true,
    );
    try {
      final id = await ApiClient.instance.saveInvoice(result.invoice, meta);
      if (!mounted) return;
      setState(() {
        item.status = BatchItemStatus.saved;
        item.savedInvoiceId = id;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.detail is Map && e.detail['error'] == 'validation_failed') {
        final rawIssues = (e.detail['issues'] as List<dynamic>? ?? []);
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
          item.errorMessage = e.toString();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.status = BatchItemStatus.failed;
        item.errorMessage = e.toString();
      });
    }
    await _persistBatch();
  }

  void _finish() {
    setState(() => _items.clear());
    _persistBatch();
    widget.onBatchFinished();
  }

  // ==================== layout ====================

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: _items.isEmpty
                ? CaptureEmptyState(
                    onTakePhoto: () => _addPhoto(ImageSource.camera),
                    onPickFromGallery: () => _addPhoto(ImageSource.gallery),
                  )
                : _buildGrid(),
          ),
          CaptureBottomBar(
            hasItems: _items.isNotEmpty,
            allResolved: _allResolved,
            hasUnresolved: _hasUnresolved,
            onTakePhoto: () => _addPhoto(ImageSource.camera),
            onPickFromGallery: () => _addPhoto(ImageSource.gallery),
            onFinish: _finish,
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(Spacing.m),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: Spacing.m,
        crossAxisSpacing: Spacing.m,
        childAspectRatio: 0.72,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
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
        );
      },
    );
  }
}
