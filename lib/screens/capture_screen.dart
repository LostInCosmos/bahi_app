import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import 'crop_screen.dart';
import 'invoice_detail_screen.dart';
import 'review_screen.dart';

/// Adobe-Scanner-style batch flow: add several bill photos (each gets its
/// corners set right after it's taken, same rhythm as "capture a page, adjust
/// its edges, capture the next"), then a single "Process" pass runs
/// extraction for the whole batch.
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
  // Every page's uploaded/cropped path, in order. Always populated once
  // preparing finishes (length 1 for the ordinary single-photo bill) so
  // every call site has one shape to deal with instead of two.
  List<String> sourceImages = [];
  _ItemStatus status = _ItemStatus.preparing;
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
  bool _processing = false;
  int _processingDone = 0;
  int _processingTotal = 0;

  bool get _hasPending => _items.any((i) => i.status == _ItemStatus.ready);
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
              // A kill mid-extraction leaves no live request to finish it --
              // restoring rewinds this back to "ready" so the item is simply
              // reprocessed instead of showing a spinner forever.
              'status': (i.status == _ItemStatus.processing ? _ItemStatus.ready : i.status).name,
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
      item.errorMessage = map['errorMessage'] as String?;
      item.savedInvoiceId = map['savedInvoiceId'] as int?;
      final resultJson = map['result'] as Map<String, dynamic>?;
      if (resultJson != null) item.result = ExtractionResult.fromJson(resultJson);
      restored.add(item);
    }
    if (restored.isEmpty || !mounted) return;
    setState(() => _items.addAll(restored));

    // Thumbnails need refetching -- raw bytes from last session are gone,
    // but the corrected image itself is still sitting on the server.
    for (final item in restored) {
      try {
        final bytes = await ApiClient.instance.fetchImage(item.sourceImages.first);
        if (!mounted) return;
        setState(() => item.correctedBytes = bytes);
      } catch (_) {
        // thumbnail just won't load for this one -- the rest of the item is still usable
      }
    }
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

  Future<void> _processOne(_BatchItem item) async {
    setState(() => item.status = _ItemStatus.processing);
    try {
      ExtractionResult result;
      try {
        result = await ApiClient.instance.extract(
          item.sourceImages.first,
          extraSourceImages: item.sourceImages.skip(1).toList(),
        );
      } on ApiException catch (e) {
        if (e.detail is Map && e.detail['error'] == 'structural_validation_failed') {
          result = ExtractionResult.blank(
            (e.detail['source_image'] as String?) ?? item.sourceImages.first,
            (e.detail['message'] as String?) ??
                "Automatic extraction couldn't read this bill — please enter its details by hand.",
          );
        } else {
          rethrow;
        }
      }

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
    } catch (e) {
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
  /// auto-saved over the existing one).
  Future<void> _reprocessItem(_BatchItem item) => _processOne(item);

  Future<void> _processAll() async {
    final pending = _items.where((i) => i.status == _ItemStatus.ready).toList();
    if (pending.isEmpty || _processing) return;
    setState(() {
      _processing = true;
      _processingDone = 0;
      _processingTotal = pending.length;
    });
    for (final item in pending) {
      await _processOne(item);
      if (!mounted) return;
      setState(() => _processingDone++);
    }
    if (mounted) setState(() => _processing = false);
  }

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
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: colors.primaryContainer, shape: BoxShape.circle),
              child: Icon(Icons.receipt_long_rounded, size: 44, color: colors.onPrimaryContainer),
            ),
            const SizedBox(height: Spacing.l),
            Text('No bills yet', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Spacing.xs),
            Text(
              'Add one or more bill photos, adjust each one\'s corners, then process them together.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => _addPhoto(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take photo'),
                ),
                const SizedBox(width: Spacing.m),
                OutlinedButton.icon(
                  onPressed: () => _addPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ],
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
            if (_processing) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.chip),
                child: LinearProgressIndicator(
                  value: _processingTotal == 0 ? null : _processingDone / _processingTotal,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: Spacing.s),
              Text(
                'Processing $_processingDone of $_processingTotal…',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Spacing.s),
            ],
            if (_items.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _processing ? null : () => _addPhoto(ImageSource.camera),
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: const Text('Add another'),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  IconButton.filledTonal(
                    onPressed: _processing ? null : () => _addPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    tooltip: 'Add from gallery',
                  ),
                ],
              ),
              const SizedBox(height: Spacing.s),
            ],
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _hasPending
                  ? FilledButton(
                      key: const ValueKey('process'),
                      onPressed: _processing
                          ? null
                          : () {
                              HapticFeedback.lightImpact();
                              _processAll();
                            },
                      child: Text('Process ${_items.where((i) => i.status == _ItemStatus.ready).length} bill(s)'),
                    )
                  : _allResolved
                      ? FilledButton.icon(
                          key: const ValueKey('done'),
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            _finish();
                          },
                          icon: const Icon(Icons.check),
                          label: const Text('Done — view purchases'),
                        )
                      : (_hasUnresolved && !_processing)
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
            else if (item.status == _ItemStatus.failed)
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
