import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/poll.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/inline_message.dart';
import '../../inventory/data/product_catalog.dart';
import '../../inventory/models/product.dart';
import '../../inventory/widgets/product_name.dart';
import '../../voice/data/voice_api.dart';
import '../../voice/models/voice.dart';
import '../../voice/presentation/voice_order_review_screen.dart';
import '../../voice/presentation/voice_sale_screen.dart';
import '../models/sale.dart';
import '../models/sale_totals.dart';
import '../widgets/discount_field.dart';
import '../widgets/stock_note.dart';
import 'sale_receipt_screen.dart';
import 'sale_review_screen.dart';

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

class SalesScreenState extends State<SalesScreen> with TabScreen {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _catalog = ProductCatalog.instance;
  Timer? _prefetchTimer;

  /// What is typed, searched on the phone as each letter is typed (DAS-94) —
  /// the same list and the same match as the Inventory tab.
  String _query = '';
  final List<CartEntry> _cart = [];
  final List<_VoiceJobItem> _voiceJobs = [];

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_onCatalog);
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
    _catalog.removeListener(_onCatalog);
    _prefetchTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onCatalog() {
    if (mounted) setState(() {});
  }

  // ==================== in-flight voice job persistence ====================
  // Same tenant-scoped SharedPreferences approach as CaptureScreen's batch
  // persistence — survives the app being killed while a note is still
  // processing, scoped per tenant so switching accounts never leaks one
  // shop's in-flight voice note into another's.
  String? _voiceJobsPrefsKey() {
    final tenantId = ApiClient.instance.tenantId;
    return tenantId == null ? null : 'bahi_voice_jobs_$tenantId';
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

  /// Fetch the shop's products again — on opening the tab and after every
  /// sale, so the stock shown is what is left.
  @override
  Future<void> refresh() => _catalog.refresh();

  /// As the search is typed, the batches of the top few matches are loaded
  /// in the background, so the one tapped opens at once. Waits for a pause
  /// in typing, and for two letters, so a whole word costs a few requests.
  void _onQuery(String typed) {
    setState(() => _query = typed);
    _prefetchTimer?.cancel();
    if (typed.trim().length < 2) return;
    _prefetchTimer = Timer(const Duration(milliseconds: 300), () {
      final matches = _catalog.index?.match(_query) ?? const <ProductSummary>[];
      _catalog.prefetchDetails(matches.take(ProductCatalog.prefetchCount).map((p) => p.id));
    });
  }

  void _clearSearch() {
    _prefetchTimer?.cancel();
    _searchController.clear();
    setState(() => _query = '');
  }

  void _openPicker(ProductSummary p) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BatchPickerSheet(
        product: p,
        onAdd: (entry) {
          setState(() => _cart.add(entry));
          Navigator.of(ctx).pop();
          // Ready for the next medicine: an empty search with the keyboard up.
          _clearSearch();
          _searchFocus.requestFocus();
          context.say('Added ${entry.productName}');
        },
      ),
    );
  }

  Future<void> _openReview() async {
    final saleId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => SaleReviewScreen(cart: _cart)),
    );
    // The review screen mutates `_cart` in place (removals, edits), so always
    // rebuild to reflect that even when the sale wasn't completed.
    if (!mounted) return;
    setState(() {
      if (saleId != null) _cart.clear();
    });
    if (saleId == null || !mounted) return;
    unawaited(refresh());
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
    unawaited(_persistVoiceJobs());
    unawaited(_pollVoiceJob(item));
  }

  Future<void> _pollVoiceJob(_VoiceJobItem item) async {
    try {
      // No interval: the server holds the request until something changes
      // (DAS-21). And no time limit: this phone used to fail a note after 180s
      // of one attempt and drop it, though the server went on to finish it. The
      // server fails a note nobody is working on (after 15 minutes), so it
      // decides — and a dropped connection is only ever "ask again", for as
      // long as this screen is open. A restart picks the note up again.
      final job = await pollUntilTerminal<VoiceOrderJob>(
        fetch: () => ApiClient.instance.getVoiceOrderJob(item.jobId, wait: true),
        isTerminal: (j) => j.isTerminal,
        transientFailures: null,
        stillWanted: () => mounted,
      );
      if (!mounted) return;
      if (job.status == 'done') {
        setState(() {
          item.status = _VoiceJobStatus.ready;
          item.order = job.order;
        });
        unawaited(_persistVoiceJobs());
        _notifyVoiceJobReady(item);
      } else {
        setState(() {
          item.status = _VoiceJobStatus.failed;
          item.errorMessage = job.errorMessage ?? 'Could not process that recording.';
        });
        unawaited(_persistVoiceJobs());
      }
    } catch (e) {
      // Only a refusal gets here (the note is gone, say) — or the screen has
      // closed, which needs nothing.
      if (!mounted) return;
      setState(() {
        item.status = _VoiceJobStatus.failed;
        item.errorMessage = e is ApiException ? 'Could not get that voice note: ${e.message}' : 'Could not get that voice note.';
      });
      unawaited(_persistVoiceJobs());
    }
  }

  /// Surfaces a job finishing as an actual pop-up notification (not just the
  /// chip strip, which the owner might not be looking at if they switched
  /// tabs or started a second recording) — tapping it opens straight into
  /// the review screen, same destination as tapping the chip.
  void _notifyVoiceJobReady(_VoiceJobItem item) {
    if (!mounted) return;
    final count = item.order?.itemCountHeard ?? 0;
    context.say(
      'Voice order ready — ${plural(count, 'item')} heard',
      action: SnackBarAction(label: 'View', onPressed: () => _openVoiceJobResult(item)),
      duration: const Duration(seconds: 6),
    );
  }

  /// Tapping a ready chip opens the review screen (same downstream flow as
  /// before — refresh stock after, show the "reversed" snackbar on undo);
  /// tapping a failed one shows the error with a way to dismiss it.
  Future<void> _openVoiceJobResult(_VoiceJobItem item) async {
    if (item.status == _VoiceJobStatus.failed) {
      // Reading the failure is dismissing it: a failed note is not worth a
      // second look, and the chip would otherwise sit there for ever.
      await showMessageDialog(context, title: 'Voice note', message: item.errorMessage ?? 'Something went wrong.');
      if (mounted) {
        setState(() => _voiceJobs.remove(item));
        unawaited(_persistVoiceJobs());
      }
      return;
    }
    if (item.status != _VoiceJobStatus.ready || item.order == null) return;
    setState(() => _voiceJobs.remove(item));
    unawaited(_persistVoiceJobs());
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => VoiceOrderReviewScreen(order: item.order!)),
    );
    if (!mounted) return;
    unawaited(refresh());
    if (result == 'undone') context.say('Sale reversed');
  }

  @override
  Widget build(BuildContext context) {
    final index = _catalog.index;
    final products = index?.match(_query) ?? const <ProductSummary>[];
    final failure = _catalog.lastError;
    final header = <Widget>[
      TextField(
        key: const ValueKey('sale-search'),
        controller: _searchController,
        focusNode: _searchFocus,
        onChanged: _onQuery,
        decoration: InputDecoration(
          labelText: 'Search a medicine to add',
          suffixIcon: _query.isEmpty
              ? const Icon(Icons.search)
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear search',
                  onPressed: _clearSearch,
                ),
        ),
        textInputAction: TextInputAction.search,
      ),
      const SizedBox(height: Spacing.m),
      if (_voiceJobs.isNotEmpty) ...[
        _buildVoiceJobsStrip(context),
        const SizedBox(height: Spacing.m),
      ],
      if (failure != null)
        ErrorText('Could not load medicines: $failure', padding: const EdgeInsets.only(bottom: Spacing.m)),
      if (index == null && _catalog.isLoading)
        const Padding(
          padding: EdgeInsets.only(top: Spacing.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (products.isEmpty && index != null)
        const Padding(
          padding: EdgeInsets.only(top: Spacing.xxl),
          child: Center(child: Text('No products found')),
        ),
    ];
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: refresh,
        // Built as they scroll into view — see InventoryScreen.
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(Spacing.l, Spacing.l, Spacing.l, 90),
          itemCount: header.length + products.length,
          itemBuilder: (context, i) {
            if (i < header.length) return header[i];
            final p = products[i - header.length];
            return Card(
              child: ListTile(
                title: ProductName(p.name, qualifier: index?.qualifier(p.id)),
                subtitle: Text('${qty(p.quantityOnHand)} in stock'),
                // The finger is down: start loading its batches now, not when
                // it lifts (already held: nothing is asked).
                trailing: Listener(
                  onPointerDown: (_) => _catalog.prefetchDetails([p.id]),
                  child: IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    // Opens with none in stock too: a sale may go beyond the stock,
                    // with a note (DAS-111). Its batch picker still blocks expiry.
                    onPressed: () => _openPicker(p),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Hidden when the admin has voice off for this shop (DAS-112).
          ValueListenableBuilder<bool>(
            valueListenable: ApiClient.instance.voiceEnabledNotifier,
            builder: (context, voiceOn, _) => voiceOn
                ? FloatingActionButton(
                    heroTag: 'voiceSaleFab',
                    tooltip: 'Voice sale',
                    onPressed: _openVoiceSale,
                    child: const Icon(Icons.mic),
                  )
                : const SizedBox.shrink(),
          ),
          if (_cart.isNotEmpty) ...[
            if (ApiClient.instance.voiceEnabledNotifier.value) const SizedBox(height: 12),
            FloatingActionButton.extended(
              heroTag: 'cartFab',
              onPressed: _openReview,
              icon: const Icon(Icons.shopping_cart),
              label: Text('View cart · ${plural(_cart.length, 'item')}'),
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
            avatar: icon == null ? const ButtonSpinner() : Icon(icon, size: 18),
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
  /// The product tapped: its name shows at once, before its batches arrive.
  final ProductSummary product;
  final void Function(CartEntry entry) onAdd;
  const _BatchPickerSheet({required this.product, required this.onAdd});

  @override
  State<_BatchPickerSheet> createState() => _BatchPickerSheetState();
}

class _BatchPickerSheetState extends State<_BatchPickerSheet> {
  ProductDetail? _detail;
  String? _error;
  final Map<int, TextEditingController> _qtyControllers = {};
  final Map<int, TextEditingController> _rateControllers = {};
  final Map<int, TextEditingController> _discountControllers = {};
  final Map<int, DiscountKind> _discountKinds = {};

  /// Batches whose Add was pressed with no usable price: only then does the
  /// empty price field turn red, so it is not an error before it is touched.
  final Set<int> _priceTried = {};

  @override
  void initState() {
    super.initState();
    // Held already (prefetched while the search was typed): shown at once,
    // with no request.
    final held = ProductCatalog.instance.detailFor(widget.product.id);
    if (held != null && _adopt(held)) return;
    _load();
  }

  /// Takes [detail] as this sheet's batches, only if it is the product this
  /// sheet was opened for: one product's batches are never shown, or sold,
  /// under another's name.
  bool _adopt(ProductDetail detail) {
    if (detail.id != widget.product.id) return false;
    for (final b in detail.batches) {
      _qtyControllers[b.id] = TextEditingController(text: '1');
      _rateControllers[b.id] = TextEditingController(text: b.mrp?.toStringAsFixed(2) ?? '');
      _discountControllers[b.id] = TextEditingController();
      _discountKinds[b.id] = DiscountKind.percentage;
    }
    _detail = detail;
    return true;
  }

  Future<void> _load() async {
    try {
      final detail = await ProductCatalog.instance.loadDetail(widget.product.id);
      if (!mounted) return;
      if (!_adopt(detail)) return setState(() => _error = 'Could not load this medicine. Close and try again.');
      setState(() {});
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode != 404) return setState(() => _error = 'Could not load product: $e');
      // Merged into another product by our team (DAS-93): the list it was
      // picked from is out of date. Fetch it again and let them pick again.
      ProductCatalog.instance.noteMergedAway();
      context.say(ProductCatalog.mergedAwayMessage);
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load product: $e');
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
    for (final c in _discountControllers.values) {
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
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProductName(widget.product.name,
                      qualifier: ProductCatalog.instance.index?.qualifier(widget.product.id),
                      style: Theme.of(context).textTheme.titleMedium),
                  SizedBox(
                    height: 120,
                    child: Center(
                      child: _error != null
                          ? Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                          : const CircularProgressIndicator(),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProductName(_detail!.name,
                      qualifier: ProductCatalog.instance.index?.qualifier(_detail!.id),
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (_detail!.batches.isEmpty) const Text('No batches in stock.'),
                  Flexible(child: SingleChildScrollView(child: Column(children: _buildBatchRows()))),
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
      // A batch with none left may still be sold, with a note (DAS-111); an
      // expired one never — the server refuses it too.
      final disabled = b.isExpired;
      final discountKind = _discountKinds[b.id] ?? DiscountKind.percentage;
      final quantity = double.tryParse(_qtyControllers[b.id]!.text) ?? 0;
      final rate = double.tryParse(_rateControllers[b.id]!.text) ?? 0;
      final discount = parseDiscount(_discountControllers[b.id]!.text, discountKind);
      final totals = computeSale([SaleLineInput(qty: quantity, rate: rate, gstPct: b.gstPct, discount: discount)]);
      // With no price there is no line to take a discount off yet.
      final discountError = rate > 0 ? totals.itemErrors[0] : null;
      final priceError = rate <= 0 && _priceTried.contains(b.id) ? 'Enter a price above ₹0' : null;
      final discounted = rate > 0 && discount != null && discountError == null && totals.itemDiscounts > 0;
      final note = quantity > 0 ? stockNote(quantity, b.quantityOnHand) : null;

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
              Text('Available: ${qty(b.quantityOnHand)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyControllers[b.id],
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Qty'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _rateControllers[b.id],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(labelText: 'Price (incl. GST)', errorText: priceError),
                    ),
                  ),
                ],
              ),
              if (note != null) StockNote(note),
              const SizedBox(height: 12),
              DiscountField(
                label: 'Discount on this item',
                controller: _discountControllers[b.id]!,
                kind: discountKind,
                onKindChanged: (k) => setState(() => _discountKinds[b.id] = k),
                onChanged: () => setState(() {}),
                errorText: discountError,
              ),
              if (discounted)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Line total ${rupees(totals.grandTotal)}  (${rupees(totals.itemDiscounts)} off)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: disabled || discountError != null
                      ? null
                      : () {
                          if (quantity <= 0) {
                            context.say('Enter a quantity above 0');
                            return;
                          }
                          // A sale with no price is almost always a missing MRP,
                          // not a gift: refuse it. A free sample is a 100% discount.
                          if (rate <= 0) {
                            setState(() => _priceTried.add(b.id));
                            return;
                          }
                          widget.onAdd(CartEntry(
                            productBatchId: b.id,
                            productName:
                                ProductCatalog.instance.index?.label(_detail!.id, _detail!.name) ?? _detail!.name,
                            batchNo: b.batchNo,
                            qty: quantity,
                            rate: rate,
                            gstPct: b.gstPct,
                            discount: discounted ? discount : null,
                            available: b.quantityOnHand,
                          ));
                        },
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}
