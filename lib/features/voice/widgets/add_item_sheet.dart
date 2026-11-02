import 'dart:async';
import 'package:flutter/material.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../inventory/data/inventory_api.dart';
import '../../inventory/data/product_catalog.dart';
import '../../inventory/models/product.dart';
import '../../inventory/widgets/product_name.dart';

class AddItemResult {
  final ProductSummary product;
  final double quantity;
  final String unit;
  const AddItemResult({required this.product, required this.quantity, required this.unit});
}

/// Search-and-pick sheet for "Add item" — a shopkeeper naming one product
/// the voice parse missed, rather than re-recording a whole note for it.
/// Pops an [AddItemResult], or null if backed out.
class AddItemSheet extends StatefulWidget {
  const AddItemSheet({super.key});

  @override
  State<AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<AddItemSheet> {
  static const _units = ['tablet', 'strip', 'capsule', 'bottle', 'tube', 'vial', 'ampoule', 'sachet'];

  final _searchController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  final _catalog = ProductCatalog.instance;

  /// What is typed, searched on the phone as each letter is typed (DAS-94).
  String _query = '';
  String? _error;
  ProductSummary? _selected;
  String _unit = 'tablet';

  // "Not in inventory" sub-flow — a small form to create the product (and
  // its first batch) right here, instead of leaving the shopkeeper stuck
  // with nothing to pick.
  bool _creatingNew = false;
  bool _creating = false;
  final _newNameController = TextEditingController();
  final _newMrpController = TextEditingController();
  final _newGstController = TextEditingController(text: '0');

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_onCatalog);
    // The list the other tabs hold is searched at once; a fresh one is asked
    // for alongside, so the stock shown here is current.
    unawaited(_catalog.refresh());
  }

  void _onCatalog() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _catalog.removeListener(_onCatalog);
    _searchController.dispose();
    _qtyController.dispose();
    _newNameController.dispose();
    _newMrpController.dispose();
    _newGstController.dispose();
    super.dispose();
  }

  void _confirm() {
    final qty = double.tryParse(_qtyController.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Enter a quantity greater than 0.');
      return;
    }
    Navigator.of(context).pop(AddItemResult(product: _selected!, quantity: qty, unit: _unit));
  }

  void _startCreatingNew() {
    _newNameController.text = _searchController.text.trim();
    setState(() {
      _creatingNew = true;
      _error = null;
    });
  }

  Future<void> _createProduct() async {
    final name = _newNameController.text.trim();
    final mrp = double.tryParse(_newMrpController.text.trim());
    final qty = double.tryParse(_qtyController.text.trim());
    final gst = double.tryParse(_newGstController.text.trim()) ?? 0;
    if (name.isEmpty) {
      setState(() => _error = 'Enter a product name.');
      return;
    }
    if (mrp == null || mrp <= 0) {
      setState(() => _error = 'Enter an MRP greater than 0.');
      return;
    }
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Enter a quantity in stock greater than 0.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final created = await ApiClient.instance.createProduct(
        name: name,
        mrp: mrp,
        quantity: qty,
        unit: _unit,
        gstPct: gst,
      );
      if (!mounted) return;
      unawaited(_catalog.refresh()); // so every search finds it from now on
      setState(() {
        _selected = created;
        _creatingNew = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create product: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final index = _catalog.index;
    final typed = _query.trim().isNotEmpty;
    // Nothing until something is typed: the whole shop is not a pick list.
    final results = typed && index != null ? index.match(_query) : const <ProductSummary>[];
    final loading = index == null && _catalog.isLoading;
    final failure = _error ??
        (index == null && _catalog.lastError != null ? 'Could not load medicines: ${_catalog.lastError}' : null);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Spacing.l,
          right: Spacing.l,
          top: Spacing.l,
          bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_creatingNew ? 'Add new product' : 'Add item', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Spacing.m),
            if (_creatingNew) ...[
              TextField(
                controller: _newNameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Product name', isDense: true),
              ),
              const SizedBox(height: Spacing.s),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newMrpController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'MRP', isDense: true, prefixText: '₹'),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: TextField(
                      controller: _newGstController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'GST %', isDense: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.s),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Quantity in stock', isDense: true),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit', isDense: true),
                      items: _units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _unit = v);
                      },
                    ),
                  ),
                ],
              ),
              ErrorText(_error, padding: const EdgeInsets.only(top: Spacing.s)),
              const SizedBox(height: Spacing.m),
              Row(
                children: [
                  TextButton(
                    onPressed: _creating ? null : () => setState(() => _creatingNew = false),
                    child: const Text('Back to search'),
                  ),
                  const Spacer(),
                  BusyFilledButton(busy: _creating, onPressed: _createProduct, label: 'Create & continue'),
                ],
              ),
            ] else if (selected == null) ...[
              TextField(
                key: const ValueKey('add-item-search'),
                controller: _searchController,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  labelText: 'Search a medicine',
                  isDense: true,
                  suffixIcon: Icon(Icons.search),
                ),
                textInputAction: TextInputAction.search,
              ),
              const SizedBox(height: Spacing.s),
              if (loading)
                const Center(child: Padding(padding: EdgeInsets.all(Spacing.m), child: CircularProgressIndicator())),
              ErrorText(failure, padding: const EdgeInsets.only(top: Spacing.s)),
              // A fixed height, not shrinkWrap: a shrink-wrapped list builds
              // every row to measure itself, and "p" alone matches hundreds.
              if (results.isNotEmpty)
                SizedBox(
                  height: (results.length * 64.0).clamp(0, MediaQuery.of(context).size.height * 0.4),
                  child: ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, i) {
                      final p = results[i];
                      return ListTile(
                        title: ProductName(p.name, qualifier: index?.qualifier(p.id)),
                        subtitle: Text('${qty(p.quantityOnHand)} in stock'),
                        enabled: p.quantityOnHand > 0,
                        onTap: () => setState(() => _selected = p),
                      );
                    },
                  ),
                ),
              if (typed && index != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.s),
                  child: TextButton.icon(
                    onPressed: _startCreatingNew,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text("Can't find it? Add as new product"),
                  ),
                ),
            ] else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: ProductName(selected.name,
                    qualifier: index?.qualifier(selected.id), style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${qty(selected.quantityOnHand)} in stock'),
                trailing: TextButton(onPressed: () => setState(() => _selected = null), child: const Text('Change')),
              ),
              const SizedBox(height: Spacing.s),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit', isDense: true),
                      items: _units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _unit = v);
                      },
                    ),
                  ),
                ],
              ),
              ErrorText(_error, padding: const EdgeInsets.only(top: Spacing.s)),
              const SizedBox(height: Spacing.m),
              FilledButton(onPressed: _confirm, child: const Text('Add to order')),
            ],
          ],
        ),
      ),
    );
  }
}
