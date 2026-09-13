import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import 'sale_receipt_screen.dart';
import 'sale_review_screen.dart';
import 'voice_order_review_screen.dart';
import 'voice_sale_screen.dart';

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
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  /// Voice sale is a second entry point into the same sell flow — parse a
  /// spoken order, let the shopkeeper review/confirm it, then refresh stock
  /// counts here exactly as after a normal cart checkout.
  Future<void> _openVoiceSale() async {
    final order = await Navigator.of(context).push<VoiceOrder>(
      MaterialPageRoute(builder: (_) => const VoiceSaleScreen()),
    );
    if (order == null || !mounted) return;
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => VoiceOrderReviewScreen(order: order)),
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
