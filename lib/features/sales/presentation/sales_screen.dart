import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../inventory/models/product.dart';
import '../models/sale.dart';
import '../../voice/models/voice.dart';
import '../../../core/utils/poll.dart';
import 'sale_receipt_screen.dart';
import 'sale_review_screen.dart';
import '../../voice/presentation/voice_order_review_screen.dart';
import '../../voice/presentation/voice_sale_screen.dart';

/// One submitted-but-not-yet-opened voice note, tracked here rather than on
/// VoiceSaleScreen itself so the owner can record a second note immediately
/// after submitting the first, instead of waiting through the ~7-10s
/// transcribe+parse round trip before they're even allowed to start another.
enum _VoiceJobStatus { processing, ready, failed }

class _VoiceJobItem {
  final int jobId;
  _VoiceJobStatus status = _VoiceJobStatus.processing;
  VoiceOrder? order;
  String? errorMessage;
  _VoiceJobItem({required this.jobId});
}

/// Same search idea as the inventory tab, different tap action — one
/// component's worth of behavior, reused instead of kept in sync twice.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => SalesScreenState();
}

class SalesScreenState extends State<SalesScreen> {
  final _searchController = TextEditingController();
  List<ProductSummary> _products = [];
  final List<CartEntry> _cart = [];
  final List<_VoiceJobItem> _voiceJobs = [];
  bool _loading = false;
  String? _error;

  static const _voiceJobPollInterval = Duration(seconds: 2);
  // Longer than bills' 120s client timeout — voice's worst-case chain
  // (transcribe up to 2 attempts x 120s + parse up to 2 attempts x 120s) is
  // genuinely longer, matching the server-side stale-after ratio.
  static const _voiceJobPollTimeout = Duration(seconds: 180);

  @override
  void initState() {
    super.initState();
    // No _search() here deliberately — see the same note in
    // purchases_screen.dart: HomeScreen's tab switcher calls refresh() the
    // first (and every) time this tab is actually selected, so every tab
    // doesn't fetch on app open. _restoreVoiceJobs still runs unconditionally
    // though — an in-flight voice note needs to resume polling regardless of
    // which tab the owner happens to be looking at.
    _restoreVoiceJobs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ==================== in-flight voice job persistence ====================
  // Same tenant-scoped SharedPreferences approach as CaptureScreen's batch
  // persistence — survives the app being killed while a note is still
  // processing, scoped per tenant so switching accounts never leaks one
  // shop's in-flight voice note into another's.
  String? _voiceJobsPrefsKey() {
    final token = ApiClient.instance.token;
    if (token == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
      final tenantId = payload['tenant_id'];
      return tenantId == null ? null : 'bahi_voice_jobs_$tenantId';
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistVoiceJobs() async {
    final key = _voiceJobsPrefsKey();
    if (key == null) return;
    // Just the job id — nothing else is worth caching locally. The server
    // already holds the full state (including the completed order once
    // done), so restore just re-polls; a "failed" job is already shown and
    // dismissible, not worth restoring as a stale chip.
    final ids = _voiceJobs.where((j) => j.status != _VoiceJobStatus.failed).map((j) => j.jobId).toList();
    final prefs = await SharedPreferences.getInstance();
    if (ids.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(ids));
    }
  }

  Future<void> _restoreVoiceJobs() async {
    final key = _voiceJobsPrefsKey();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return;
    List<dynamic> ids;
    try {
      ids = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return;
    }
    if (ids.isEmpty || !mounted) return;
    // A restored job is always resumed by polling again, whatever it was
    // doing last session — a job that already finished resolves on the
    // very first poll (the server still has the full result), and a
    // still-processing one just picks the poll loop back up.
    final restored = ids.map((id) => _VoiceJobItem(jobId: id as int)).toList();
    setState(() => _voiceJobs.addAll(restored));
    for (final item in restored) {
      unawaited(_pollVoiceJob(item));
    }
  }

  Future<void> refresh() => _search();

  Future<void> _search() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final products = await ApiClient.instance.searchProducts(q: _searchController.text.trim());
      if (!mounted) return;
      setState(() => _products = products);
    } catch (e) {
      setState(() => _error = 'Could not search: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openPicker(ProductSummary p) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BatchPickerSheet(
        productId: p.id,
        onAdd: (entry) {
          setState(() => _cart.add(entry));
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  Future<void> _openReview() async {
    final saleId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => SaleReviewScreen(cart: _cart)),
    );
    // The review screen mutates `_cart` in place (removals), so always
    // rebuild to reflect that even when the sale wasn't completed.
    setState(() {
      if (saleId != null) _cart.clear();
    });
    if (saleId == null || !mounted) return;
    _search();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SaleReceiptScreen(saleId: saleId)),
    );
  }

  /// Voice sale is a second entry point into the same sell flow — record a
  /// spoken order, then let the shopkeeper review/confirm it once parsing
  /// finishes, refreshing stock counts here exactly as after a normal cart
  /// checkout. VoiceSaleScreen pops with a job id the moment the recording
  /// is submitted (not once it's parsed) — that's tracked here, in
  /// _voiceJobs, instead of blocking on it, so the owner can immediately
  /// record a second note without waiting for the first to finish.
  Future<void> _openVoiceSale() async {
    final jobId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const VoiceSaleScreen()),
    );
    if (jobId == null || !mounted) return;
    final item = _VoiceJobItem(jobId: jobId);
    setState(() => _voiceJobs.add(item));
    _persistVoiceJobs();
    unawaited(_pollVoiceJob(item));
  }

  Future<void> _pollVoiceJob(_VoiceJobItem item) async {
    try {
      final job = await pollUntilTerminal<VoiceOrderJob>(
        fetch: () => ApiClient.instance.getVoiceOrderJob(item.jobId),
        isTerminal: (j) => j.isTerminal,
        interval: _voiceJobPollInterval,
        timeout: _voiceJobPollTimeout,
      );
      if (!mounted) return;
      if (job.status == 'done') {
        setState(() {
          item.status = _VoiceJobStatus.ready;
          item.order = job.order;
        });
        _persistVoiceJobs();
        _notifyVoiceJobReady(item);
      } else {
        setState(() {
          item.status = _VoiceJobStatus.failed;
          item.errorMessage = job.errorMessage ?? 'Could not process that recording.';
        });
        _persistVoiceJobs();
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        item.status = _VoiceJobStatus.failed;
        item.errorMessage = 'This is taking longer than expected — please try again.';
      });
      _persistVoiceJobs();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        item.status = _VoiceJobStatus.failed;
        item.errorMessage = 'Could not reach the server.';
      });
      _persistVoiceJobs();
    }
  }

  /// Surfaces a job finishing as an actual pop-up notification (not just the
  /// chip strip, which the owner might not be looking at if they switched
  /// tabs or started a second recording) — tapping it opens straight into
  /// the review screen, same destination as tapping the chip.
  void _notifyVoiceJobReady(_VoiceJobItem item) {
    if (!mounted) return;
    final count = item.order?.itemCountHeard ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Voice order ready — $count item${count == 1 ? '' : 's'} heard'),
        action: SnackBarAction(label: 'View', onPressed: () => _openVoiceJobResult(item)),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// Tapping a ready chip opens the review screen (same downstream flow as
  /// before — refresh stock after, show the "reversed" snackbar on undo);
  /// tapping a failed one shows the error with a way to dismiss it.
  Future<void> _openVoiceJobResult(_VoiceJobItem item) async {
    if (item.status == _VoiceJobStatus.failed) {
      final dismiss = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Voice note'),
          content: Text(item.errorMessage ?? 'Something went wrong.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Dismiss'))],
        ),
      );
      if (dismiss == true && mounted) {
        setState(() => _voiceJobs.remove(item));
        _persistVoiceJobs();
      }
      return;
    }
    if (item.status != _VoiceJobStatus.ready || item.order == null) return;
    setState(() => _voiceJobs.remove(item));
    _persistVoiceJobs();
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => VoiceOrderReviewScreen(order: item.order!)),
    );
    if (!mounted) return;
    _search();
    if (result == 'undone') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sale reversed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _search,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search a medicine to add',
                suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            if (_voiceJobs.isNotEmpty) ...[
              _buildVoiceJobsStrip(context),
              const SizedBox(height: 12),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_products.isEmpty && !_loading)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Center(child: Text('No products found')),
              ),
            ..._products.map((p) => Card(
                  child: ListTile(
                    title: Text(p.name),
                    subtitle: Text('${p.quantityOnHand.toStringAsFixed(0)} in stock'),
                    trailing: IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: p.quantityOnHand > 0 ? () => _openPicker(p) : null,
                    ),
                  ),
                )),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'voiceSaleFab',
            tooltip: 'Voice sale',
            onPressed: _openVoiceSale,
            child: const Icon(Icons.mic),
          ),
          if (_cart.isNotEmpty) ...[
            const SizedBox(height: 12),
            FloatingActionButton.extended(
              heroTag: 'cartFab',
              onPressed: _openReview,
              icon: const Icon(Icons.shopping_cart),
              label: Text('View cart · ${_cart.length} item${_cart.length == 1 ? '' : 's'}'),
            ),
          ],
        ],
      ),
    );
  }

  /// Compact strip of in-flight/finished voice notes — a shop owner can
  /// have several going at once now that recording one doesn't block
  /// starting the next, so each gets its own small tappable chip instead
  /// of one modal spinner.
  Widget _buildVoiceJobsStrip(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _voiceJobs.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final item = _voiceJobs[i];
          final (icon, label, color) = switch (item.status) {
            _VoiceJobStatus.processing => (null, 'Voice note…', colors.secondaryContainer),
            _VoiceJobStatus.ready => (Icons.check_circle, 'Voice note ready', colors.primaryContainer),
            _VoiceJobStatus.failed => (Icons.error_outline, 'Voice note failed', colors.errorContainer),
          };
          return ActionChip(
            avatar: icon == null
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon, size: 18),
            label: Text(label),
            backgroundColor: color,
            onPressed: item.status == _VoiceJobStatus.processing ? null : () => _openVoiceJobResult(item),
          );
        },
      ),
    );
  }
}

/// Bottom sheet for one product: pick a batch (soonest-expiring one flagged
/// "suggested", never forced — a customer asking for a longer-dated pack is
/// common enough that overriding it needs to be one tap), a quantity and a
/// price, then add that line to the cart.
class _BatchPickerSheet extends StatefulWidget {
  final int productId;
  final void Function(CartEntry entry) onAdd;
  const _BatchPickerSheet({required this.productId, required this.onAdd});

  @override
  State<_BatchPickerSheet> createState() => _BatchPickerSheetState();
}

class _BatchPickerSheetState extends State<_BatchPickerSheet> {
  ProductDetail? _detail;
  String? _error;
  final Map<int, TextEditingController> _qtyControllers = {};
  final Map<int, TextEditingController> _rateControllers = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail = await ApiClient.instance.getProductDetail(widget.productId);
      if (!mounted) return;
      for (final b in detail.batches) {
        _qtyControllers[b.id] = TextEditingController(text: '1');
        _rateControllers[b.id] = TextEditingController(text: b.mrp?.toStringAsFixed(2) ?? '');
      }
      setState(() => _detail = detail);
    } catch (e) {
      setState(() => _error = 'Could not load product: $e');
    }
  }

  @override
  void dispose() {
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    for (final c in _rateControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: _detail == null
            ? SizedBox(
                height: 160,
                child: Center(
                  child: _error != null
                      ? Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                      : const CircularProgressIndicator(),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_detail!.name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (_detail!.batches.isEmpty) const Text('No batches in stock.'),
                  ..._buildBatchRows(),
                ],
              ),
      ),
    );
  }

  List<Widget> _buildBatchRows() {
    bool suggestedShown = false;
    return _detail!.batches.map((b) {
      final isSuggested = !suggestedShown && !b.isExpired && b.quantityOnHand > 0;
      if (isSuggested) suggestedShown = true;
      final disabled = b.isExpired || b.quantityOnHand <= 0;

      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Batch ${b.batchNo ?? "—"}${isSuggested ? "  (suggested)" : ""}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  Text(
                    b.expiryDate ?? '—',
                    style: TextStyle(color: b.isExpired ? Theme.of(context).colorScheme.error : null),
                  ),
                ],
              ),
              Text('Available: ${b.quantityOnHand.toStringAsFixed(0)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyControllers[b.id],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _rateControllers[b.id],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Price', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: disabled
                        ? null
                        : () {
                            final qty = double.tryParse(_qtyControllers[b.id]!.text) ?? 0;
                            final rate = double.tryParse(_rateControllers[b.id]!.text) ?? 0;
                            if (qty <= 0 || qty > b.quantityOnHand) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'Enter a quantity between 1 and ${b.quantityOnHand.toStringAsFixed(0)}'),
                                ),
                              );
                              return;
                            }
                            widget.onAdd(CartEntry(
                              productBatchId: b.id,
                              productName: _detail!.name,
                              batchNo: b.batchNo,
                              qty: qty,
                              rate: rate,
                              gstPct: b.gstPct,
                            ));
                          },
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}
