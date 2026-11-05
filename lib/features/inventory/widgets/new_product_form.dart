import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../data/inventory_api.dart';
import '../data/product_catalog.dart';

/// The units a product typed in by hand can be counted in.
const kProductUnits = ['tablet', 'strip', 'capsule', 'bottle', 'tube', 'vial', 'ampoule', 'sachet'];

/// The form that creates a product the shop does not have yet: name, MRP,
/// GST and unit. With [askQuantity] it also takes the stock (the voice
/// orders' "Add item" box); without it the product starts at 0 stock, to be
/// billed at once from the Sell tab (DAS-172), and [source] says so.
///
/// On success the catalog is refreshed (so every search finds the product)
/// and [onCreated] gets the product and its one batch.
class NewProductForm extends StatefulWidget {
  final String initialName;
  final bool askQuantity;
  final String? source;
  final void Function(CreatedProduct created) onCreated;

  /// The "Back" action, when the form sits inside another sheet.
  final VoidCallback? onBack;
  final String backLabel;

  const NewProductForm({
    super.key,
    this.initialName = '',
    this.askQuantity = false,
    this.source,
    required this.onCreated,
    this.onBack,
    this.backLabel = 'Back',
  });

  @override
  State<NewProductForm> createState() => _NewProductFormState();
}

class _NewProductFormState extends State<NewProductForm> {
  late final _nameController = TextEditingController(text: widget.initialName);
  final _mrpController = TextEditingController();
  final _gstController = TextEditingController(text: '0');
  final _qtyController = TextEditingController(text: '1');
  String _unit = 'tablet';
  String? _error;
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _mrpController.dispose();
    _gstController.dispose();
    _qtyController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final mrp = double.tryParse(_mrpController.text.trim());
    final gst = double.tryParse(_gstController.text.trim()) ?? 0;
    final qty = widget.askQuantity ? double.tryParse(_qtyController.text.trim()) : 0.0;
    if (name.isEmpty) return setState(() => _error = 'Enter a product name.');
    if (mrp == null || mrp <= 0) return setState(() => _error = 'Enter an MRP greater than 0.');
    if (gst < 0 || gst > 100) return setState(() => _error = 'Enter a GST rate from 0 to 100.');
    if (qty == null || qty < 0 || (widget.askQuantity && qty <= 0)) {
      return setState(() => _error = 'Enter a quantity in stock greater than 0.');
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
        source: widget.source,
      );
      if (!mounted) return;
      unawaited(ProductCatalog.instance.refresh()); // so every search finds it from now on
      widget.onCreated(created);
    } on ApiException catch (e) {
      // 409: the name already matches one of the shop's products; the server
      // names it, so the shopkeeper picks that one instead of making a twin.
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create product: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('new-product-name'),
          controller: _nameController,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Product name', isDense: true),
        ),
        const SizedBox(height: Spacing.s),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('new-product-mrp'),
                controller: _mrpController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'MRP', isDense: true, prefixText: '₹'),
              ),
            ),
            const SizedBox(width: Spacing.s),
            Expanded(
              child: TextField(
                key: const ValueKey('new-product-gst'),
                controller: _gstController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'GST %', isDense: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.s),
        Row(
          children: [
            if (widget.askQuantity) ...[
              Expanded(
                child: TextField(
                  controller: _qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Quantity in stock', isDense: true),
                ),
              ),
              const SizedBox(width: Spacing.s),
            ],
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _unit,
                decoration: const InputDecoration(labelText: 'Unit', isDense: true),
                items: kProductUnits.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _unit = v);
                },
              ),
            ),
          ],
        ),
        if (!widget.askQuantity)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.s),
            child: Text(
              'Stock starts at 0. Our team fills in the rest (HSN, pack) after checking it.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ErrorText(_error, padding: const EdgeInsets.only(top: Spacing.s)),
        const SizedBox(height: Spacing.m),
        // Wraps on a narrow phone instead of overflowing.
        OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          spacing: Spacing.s,
          children: [
            if (widget.onBack != null)
              TextButton(onPressed: _creating ? null : widget.onBack, child: Text(widget.backLabel)),
            BusyFilledButton(busy: _creating, onPressed: _create, label: 'Create & continue'),
          ],
        ),
      ],
    );
  }
}

/// [NewProductForm] as a bottom sheet of its own. Pops with what was created,
/// or null if backed out.
Future<CreatedProduct?> showNewProductSheet(BuildContext context, {String initialName = '', String? source}) =>
    showModalBottomSheet<CreatedProduct>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              Spacing.l, Spacing.l, Spacing.l, MediaQuery.of(ctx).viewInsets.bottom + Spacing.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add new product', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: Spacing.m),
              NewProductForm(
                initialName: initialName,
                source: source,
                onBack: () => Navigator.of(ctx).pop(),
                backLabel: 'Cancel',
                onCreated: (created) => Navigator.of(ctx).pop(created),
              ),
            ],
          ),
        ),
      ),
    );
