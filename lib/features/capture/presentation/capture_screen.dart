import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../invoice/models/invoice.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/utils/poll.dart';
import 'crop_screen.dart';
import '../../invoice/presentation/invoice_detail_screen.dart';
import '../../invoice/presentation/review_screen.dart';

/// Adobe-Scanner-style batch flow: add several bill photos (each gets its
/// corners set right after it's taken, same rhythm as "capture a page, adjust
/// its edges, capture the next"). Extraction for each bill starts on its own,
/// the moment that bill finishes cropping — there's no separate "Process"
/// step to wait on or tap, so a user can go straight into capturing the next
/// bill while the previous one is still being read in the background.
///
/// Nothing saves itself, ever. validation.py only catches internal
/// arithmetic inconsistency — it has no way to know whether Gemini actually
/// read the vendor name or amount correctly, and that accuracy hasn't been
/// established against real bills yet. So even a "clean" result (zero
/// validation issues) only reaches `pendingConfirm`: a one-tap summary the
/// user must actually confirm before it's written to the database. Anything
/// with an issue, a likely duplicate, or an extraction that didn't come back
/// readable goes to `needsReview` and opens the full edit form instead.
/// Either way it's anchored to that item's own photo so it's always clear
/// which physical bill needs attention.
enum _ItemStatus { preparing, ready, processing, pendingConfirm, saved, needsReview, failed }

/// One captured photo, already cropped client-side, waiting to be uploaded.
/// A bill spanning multiple photos (see CaptureScreen's "+ Add another
/// page") becomes several of these under one _BatchItem.
class _BatchItemPage {
  final Uint8List rawBytes;
  final String rawFilename;
  final List<Offset2D> corners;
  final int rotationDegrees;
  _BatchItemPage({
    required this.rawBytes,
    required this.rawFilename,
    required this.corners,
    required this.rotationDegrees,
  });
}

class _BatchItem {
  final String label;
  // Raw pages queued for upload — cleared (set to []) once every page has
  // been preprocessed, since sourceImages is the only thing needed after
  // that (and raw bytes for several full-res photos add up fast).
  List<_BatchItemPage> pages;

  Uint8List? correctedBytes; // first page's corrected image, for the thumbnail
  // The thumbnail download failed. Distinct from `status`: the BILL can be
  // perfectly fine (extracted, reviewable) while only its picture is missing.
  // Without this the card cannot tell "still downloading" from "never will",
  // and a failed fetch span forever under a progress spinner.
  bool thumbnailFailed = false;
  // Every page's uploaded/cropped path, in order. Always populated once
  // preparing finishes (length 1 for the ordinary single-photo bill) so
  // every call site has one shape to deal with instead of two.
  List<String> sourceImages = [];
  _ItemStatus status = _ItemStatus.preparing;
  // Set the moment extraction is submitted (see _processOne) and cleared
  // once it reaches a terminal state — persisted across an app kill so
  // _restoreBatch can resume polling the SAME job instead of resubmitting
  // one that's still (or already) running server-side.
  int? jobId;
  // Unlike jobId above, this is never cleared once set — it's this item's
  // extraction_logs row for as long as the batch item exists. A "resend to
  // Gemini" tap (_reprocessItem) uses it to retry that SAME row via
  // ApiClient.retryExtraction instead of submitExtraction, which would
  // otherwise create a brand-new row (and a brand-new "attempts: 1") every
  // single retry instead of the row honestly accumulating both.
  int? lastJobId;
  ExtractionResult? result;
  String? errorMessage;
  int? savedInvoiceId;

  _BatchItem({required this.label, required this.pages});
}

class CaptureScreen extends StatefulWidget {
  final VoidCallback onBatchFinished;
  const CaptureScreen({super.key, required this.onBatchFinished});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final List<_BatchItem> _items = [];

  bool get _hasUnresolved => _items.any((i) =>
      i.status == _ItemStatus.needsReview ||
      i.status == _ItemStatus.failed ||
      i.status == _ItemStatus.pendingConfirm);
  bool get _allResolved =>
      _items.isNotEmpty && _items.every((i) => i.status == _ItemStatus.saved);

  @override
  void initState() {
    super.initState();
    _restoreBatch();
  }

  // ==================== batch persistence ====================
  // Survives the app being killed and relaunched — everything here lives
  // only in this State's memory otherwise, exactly the failure mode that
  // motivated the web app's equivalent localStorage-backed persistence.
  // Scoped per tenant (decoded from the JWT, not re-fetched from the
  // server) so switching accounts on the same device never leaks one
  // tenant's in-progress bills into another's.
  String? _batchPrefsKey() {
    final token = ApiClient.instance.token;
    if (token == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
      final tenantId = payload['tenant_id'];
      return tenantId == null ? null : 'bahi_batch_$tenantId';
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistBatch() async {
    final key = _batchPrefsKey();
    if (key == null) return;
    final serializable = _items
        .where((i) => i.sourceImages.isNotEmpty)
        .map((i) => {
              'label': i.label,
              'sourceImages': i.sourceImages,
              // Extraction now runs server-side in a worker, independent of
              // this app's own lifetime — a kill mid-extraction no longer
              // means the work was lost, so "processing" only rewinds to
              // "ready" (forcing a fresh resubmit) in the narrow window
              // where a job was about to be submitted but jobId isn't set
              // yet. Otherwise _restoreBatch resumes polling the same job.
              'status': (i.status == _ItemStatus.processing && i.jobId == null ? _ItemStatus.ready : i.status).name,
              'jobId': i.jobId,
              'lastJobId': i.lastJobId,
              'result': i.result?.toJson(),
              'errorMessage': i.errorMessage,
              'savedInvoiceId': i.savedInvoiceId,
            })
        .toList();
    final prefs = await SharedPreferences.getInstance();
    if (serializable.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(serializable));
    }
  }

  Future<void> _restoreBatch() async {
    final key = _batchPrefsKey();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return;
    List<dynamic> saved;
    try {
      saved = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return;
    }
    if (saved.isEmpty) return;

    final restored = <_BatchItem>[];
    for (final entry in saved) {
      final map = entry as Map<String, dynamic>;
      final sourceImages = (map['sourceImages'] as List<dynamic>? ?? []).map((e) => e as String).toList();
      if (sourceImages.isEmpty) continue;
      final item = _BatchItem(label: map['label'] as String? ?? 'Photo', pages: []);
      item.sourceImages = sourceImages;
      item.status = _ItemStatus.values.firstWhere(
        (v) => v.name == map['status'],
        orElse: () => _ItemStatus.ready,
      );
      item.jobId = map['jobId'] as int?;
      // Older persisted batches (saved before lastJobId existed) have no
      // key for it — fall back to jobId, which is the same value for any
      // item whose FIRST submission hadn't reached a terminal state yet
      // when the batch was last saved; an item that had already finished
      // simply won't get a retry-reuse for its pre-upgrade row, and starts
      // a fresh one on next resend, same as before this existed.
      item.lastJobId = map['lastJobId'] as int? ?? item.jobId;
      item.errorMessage = map['errorMessage'] as String?;
      item.savedInvoiceId = map['savedInvoiceId'] as int?;
      final resultJson = map['result'] as Map<String, dynamic>?;
      if (resultJson != null) item.result = ExtractionResult.fromJson(resultJson);
      restored.add(item);
    }
    if (restored.isEmpty || !mounted) return;
    setState(() => _items.addAll(restored));

    // Resuming extraction must NOT wait on pictures. It used to run after
    // each thumbnail inside one sequential loop, so a dozen slow downloads
    // held up a dozen jobs -- and an unmount partway through abandoned every
    // item after that point.
    for (final item in restored) {
      // A "ready" item here means a job was never actually submitted last
      // session (see the status-rewind comment in _persistBatch) -- start
      // fresh, automatically, the same way a freshly-cropped bill does. A
      // "processing" item with a jobId means a job WAS submitted and may
      // already be done server-side -- resume polling that same job rather
      // than submitting a second one and wasting a real Gemini call.
      if (item.status == _ItemStatus.ready) {
        unawaited(_processOne(item));
      } else if (item.status == _ItemStatus.processing && item.jobId != null) {
        unawaited(_processOne(item, resumeJobId: item.jobId));
      }
    }
    unawaited(_loadThumbnails(restored));
  }

  /// Fills in each restored card's picture. Cached images (the usual case
  /// after the first run) come off the device; the rest are fetched together
  /// rather than one after another, since a dozen bills used to mean a dozen
  /// serial full-resolution downloads before the grid finished drawing.
  Future<void> _loadThumbnails(List<_BatchItem> items) async {
    await Future.wait(items.map((item) async {
      if (item.sourceImages.isEmpty) return;
      try {
        final bytes = await ApiClient.instance.fetchImage(item.sourceImages.first);
        if (!mounted) return;
        setState(() => item.correctedBytes = bytes);
      } catch (_) {
        // The bill itself is still usable -- only its picture is missing, so
        // the card has to say so rather than spin. One failure must not stop
        // the others, hence per-item handling inside the wait.
        if (!mounted) return;
        setState(() => item.thumbnailFailed = true);
      }
    }));
  }

  /// Captures one or more photos for a single bill: after each crop, the
  /// user can either finish or tap "+ Add another page" to keep capturing
  /// pages for the SAME bill before it becomes one batch item.
  Future<void> _addPhoto(ImageSource source) async {
    final pages = <_BatchItemPage>[];
    while (true) {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: source, imageQuality: 95);
      if (file == null) {
        if (pages.isEmpty) return;
        break; // cancelled a continuation page -- keep what's already queued
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

      pages.add(_BatchItemPage(
        rawBytes: bytes,
        rawFilename: file.name,
        corners: cropResult.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: cropResult.rotationDegrees,
      ));

      if (!cropResult.addAnotherPage) break;
    }

    final item = _BatchItem(label: 'Photo ${_items.length + 1}', pages: pages);
    setState(() => _items.add(item));
    await _preprocessItem(item);
    // Starts extraction the moment this bill is ready, without waiting for
    // the caller (this function) to return — so the "Add another"/gallery
    // buttons are free again immediately and the user can go straight into
    // capturing the next bill while this one is read in the background.
    if (item.status == _ItemStatus.ready) {
      unawaited(_processOne(item));
    }
  }

  Future<void> _preprocessItem(_BatchItem item) async {
    setState(() => item.status = _ItemStatus.preparing);
    try {
      final sourceImages = <String>[];
      for (final page in item.pages) {
        final sourceImage = await ApiClient.instance.preprocess(
          imageBytes: page.rawBytes,
          filename: page.rawFilename,
          corners: page.corners,
          rotationDegrees: page.rotationDegrees,
        );
        sourceImages.add(sourceImage);
      }
      final corrected = await ApiClient.instance.fetchImage(sourceImages.first);
      if (!mounted) return;
      setState(() {
        item.sourceImages = sourceImages;
        item.pages = [];
        item.correctedBytes = corrected;
        item.status = _ItemStatus.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.status = _ItemStatus.failed;
        item.errorMessage = 'Crop failed: $e';
      });
    }
    _persistBatch();
  }

  void _removeItem(_BatchItem item) {
    setState(() => _items.remove(item));
    _persistBatch();
  }

  // How long a single job is allowed to sit in pending/processing before
  // this poll loop gives up client-side — independent of (and shorter than)
  // the worker's own stale-job reclaim (EXTRACTION_JOB_STALE_AFTER_MINUTES,
  // 10 min server-side): this just keeps one bill's spinner from running
  // forever in the UI if something is genuinely stuck; the job itself is
  // still safe and will get reclaimed/retried server-side regardless.
  static const _pollTimeout = Duration(seconds: 120);
  static const _pollInterval = Duration(seconds: 2);

  /// Submits (or, if [resumeJobId] is given, resumes polling an
  /// already-submitted) extraction job and waits for it to finish. Extraction
  /// itself now runs in a background worker, not inline in one HTTP call —
  /// see ApiClient.submitExtraction/getExtractionJob — so this is a
  /// submit-then-poll loop instead of a single awaited request.
  Future<void> _processOne(_BatchItem item, {int? resumeJobId}) async {
    setState(() => item.status = _ItemStatus.processing);
    try {
      int jobId;
      if (resumeJobId != null) {
        jobId = resumeJobId;
      } else if (item.lastJobId != null) {
        // Not this item's first attempt — reuse the existing row instead of
        // submitExtraction, which would spawn a separate one every retry.
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

      item.jobId = null;
      if (!mounted) return;
      setState(() {
        // Zero validation issues means the numbers are internally
        // consistent, not that the extraction is correct — that's still
        // unverified against real bills, so this still waits on a human tap
        // rather than saving itself. Anything with an issue skips straight
        // to the full edit form instead of a summary confirm.
        item.status = result.issues.isEmpty ? _ItemStatus.pendingConfirm : _ItemStatus.needsReview;
        item.result = result;
      });
    } on TimeoutException {
      item.jobId = null;
      if (!mounted) return;
      setState(() {
        item.status = _ItemStatus.failed;
        item.errorMessage = "This bill is taking longer than expected — please try again.";
      });
    } catch (e) {
      item.jobId = null;
      if (!mounted) return;
      setState(() {
        item.status = _ItemStatus.failed;
        item.errorMessage = e.toString();
      });
    }
    _persistBatch();
  }

  /// Re-runs extraction on an already-uploaded image — available any time
  /// there's a source image to re-extract and nothing already in flight for
  /// it, including on an already-saved bill (the fresh result just isn't
  /// auto-saved over the existing one). Always submits a fresh job, never
  /// resumes — this is an explicit "try again", not a restore.
  Future<void> _reprocessItem(_BatchItem item) => _processOne(item);

  Future<void> _openItem(_BatchItem item) async {
    if (item.status == _ItemStatus.saved) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => InvoiceDetailScreen(invoiceId: item.savedInvoiceId!)),
      );
      return;
    }
    if (item.status == _ItemStatus.failed) {
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
      if (retry == true) {
        // A crop/preprocess failure never got a sourceImage — retry that
        // step, not extraction (which would crash with no image to send).
        await (item.sourceImages.isEmpty ? _preprocessItem(item) : _processOne(item));
      }
      return;
    }

    if (item.status == _ItemStatus.pendingConfirm) {
      final result = item.result!;
      final inv = result.invoice;
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(item.label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(inv.sellerName, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('GSTIN ${inv.sellerGstin}'),
              const SizedBox(height: 8),
              Text('Invoice ${inv.invoiceNo} • ${inv.invoiceDate}'),
              Text('${inv.lineItems.length} item(s)'),
              const SizedBox(height: 8),
              Text(
                'Grand total: ₹${inv.totals.grandTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Not now')),
            OutlinedButton(onPressed: () => Navigator.pop(context, 'edit'), child: const Text('Edit')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Looks good — save')),
          ],
        ),
      );
      if (!mounted) return;

      if (action == 'save') {
        await _confirmAndSave(item, result);
      } else if (action == 'edit') {
        final savedId = await Navigator.of(context).push<int>(
          MaterialPageRoute(
            builder: (_) => ReviewScreen(
              result: result,
              onRevalidated: (updatedResult, hasErrors) {
                setState(() {
                  item.result = updatedResult;
                  item.status = hasErrors ? _ItemStatus.needsReview : _ItemStatus.pendingConfirm;
                });
                _persistBatch();
              },
            ),
          ),
        );
        if (savedId != null && mounted) {
          setState(() {
            item.status = _ItemStatus.saved;
            item.savedInvoiceId = savedId;
          });
          _persistBatch();
        }
      }
      return;
    }

    final result = item.result;
    if (result == null) return;
    final savedId = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          result: result,
          onRevalidated: (updatedResult, hasErrors) {
            setState(() {
              item.result = updatedResult;
              item.status = hasErrors ? _ItemStatus.needsReview : _ItemStatus.pendingConfirm;
            });
            _persistBatch();
          },
        ),
      ),
    );
    if (savedId != null && mounted) {
      setState(() {
        item.status = _ItemStatus.saved;
        item.savedInvoiceId = savedId;
      });
      _persistBatch();
    }
  }

  /// Only reached from the one-tap confirm dialog above — never called
  /// automatically. A duplicate can still surface here even though the
  /// extract-time validation was clean, since the duplicate check only runs
  /// at save time; that's treated the same as any other validation issue.
  Future<void> _confirmAndSave(_BatchItem item, ExtractionResult result) async {
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
        item.status = _ItemStatus.saved;
        item.savedInvoiceId = id;
      });
    } on ApiException catch (e) {
      if (e.detail is Map && e.detail['error'] == 'validation_failed') {
        final rawIssues = (e.detail['issues'] as List<dynamic>? ?? []);
        if (!mounted) return;
        setState(() {
          item.status = _ItemStatus.needsReview;
          item.result = ExtractionResult(
            invoice: result.invoice,
            meta: result.meta,
            issues: rawIssues.map((j) => ValidationIssue.fromJson(j as Map<String, dynamic>)).toList(),
          );
        });
      } else {
        if (!mounted) return;
        setState(() {
          item.status = _ItemStatus.failed;
          item.errorMessage = e.toString();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.status = _ItemStatus.failed;
        item.errorMessage = e.toString();
      });
    }
    _persistBatch();
  }

  void _finish() {
    setState(() => _items.clear());
    _persistBatch();
    widget.onBatchFinished();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: _items.isEmpty ? _buildEmptyState(context) : _buildGrid(),
          ),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              height: 200,
              decoration: BoxDecoration(
                color: AppColors.spotSurface,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Icon(Icons.receipt_long_rounded, size: 56, color: AppColors.spotSurfaceOn.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: Spacing.xl),
            Text('Scan your first bill', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Spacing.xs),
            Text(
              "Add one or more bill photos. You can adjust every page's corners before processing them together.",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.l),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.m, vertical: Spacing.s),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_outlined, size: 16, color: colors.onSurfaceVariant),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      'Long bill? Add as many pages as you need.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.xl),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _addPhoto(ImageSource.camera),
                icon: const Icon(Icons.camera_alt),
                label: const Text('Take photo'),
              ),
            ),
            const SizedBox(height: Spacing.s),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _addPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose from Gallery'),
              ),
            ),
          ],
        ),
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
      itemBuilder: (context, i) => _ItemCard(
        key: ValueKey(_items[i]),
        item: _items[i],
        onTap: () => _openItem(_items[i]),
        onDelete: _items[i].status != _ItemStatus.processing && _items[i].status != _ItemStatus.saved
            ? () => _removeItem(_items[i])
            : null,
        onReprocess: _items[i].sourceImages.isNotEmpty &&
                _items[i].status != _ItemStatus.preparing &&
                _items[i].status != _ItemStatus.processing
            ? () => _reprocessItem(_items[i])
            : null,
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
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
            if (_items.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _addPhoto(ImageSource.camera),
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: const Text('Add another'),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  IconButton.filledTonal(
                    onPressed: () => _addPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    tooltip: 'Add from gallery',
                  ),
                ],
              ),
              const SizedBox(height: Spacing.s),
            ],
            // Every bill starts processing on its own as soon as it's
            // cropped (see _addPhoto/_restoreBatch) — nothing here waits on
            // a manual "Process" step, so this only ever needs to show
            // either "you're all done" or "something still needs a look".
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _allResolved
                  ? FilledButton.icon(
                      key: const ValueKey('done'),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        _finish();
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Done — view purchases'),
                    )
                  : _hasUnresolved
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

class _ItemCard extends StatelessWidget {
  final _BatchItem item;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onReprocess;
  const _ItemCard({super.key, required this.item, required this.onTap, required this.onDelete, required this.onReprocess});

  @override
  Widget build(BuildContext context) {
    final pageCount = item.sourceImages.length;
    final busy = item.status == _ItemStatus.preparing || item.status == _ItemStatus.processing;
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
            else if (item.status == _ItemStatus.failed || item.thumbnailFailed)
              const Center(child: Icon(Icons.broken_image_outlined, size: 40, color: Colors.grey))
            else
              const Center(child: CircularProgressIndicator()),
            // Bottom scrim so the label stays legible over any photo,
            // gradient rather than a flat bar so it reads as part of the
            // card's finish, not a slapped-on strip.
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
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
              child: item.status == _ItemStatus.processing
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
      case _ItemStatus.saved:
        return const _Badge(color: AppColors.statusSaved, icon: Icons.check_rounded);
      case _ItemStatus.pendingConfirm:
        return const _Badge(color: AppColors.statusPendingConfirm, icon: Icons.touch_app_rounded);
      case _ItemStatus.needsReview:
        return const _Badge(color: AppColors.statusNeedsReview, icon: Icons.priority_high_rounded);
      case _ItemStatus.failed:
        return _Badge(color: Theme.of(context).colorScheme.error, icon: Icons.close_rounded);
      case _ItemStatus.ready:
        return const _Badge(color: AppColors.statusReady, icon: Icons.hourglass_empty_rounded);
      case _ItemStatus.preparing:
      case _ItemStatus.processing:
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

/// A small translucent circular icon button used for overlay controls
/// (delete, reprocess) that sit directly on top of a photo — needs its own
/// dark chip so it stays legible against any bill photo, not just dark ones.
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
