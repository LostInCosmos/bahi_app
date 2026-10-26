import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../invoice/presentation/invoice_detail_screen.dart';
import '../data/inventory_api.dart';
import '../data/product_catalog.dart';
import '../models/product.dart';
import '../widgets/product_name.dart';

/// Batches sort soonest-expiry first (FEFO) — the same order the sale
/// screen's batch picker suggests from, shown here so a shop owner can see
/// why a particular batch gets suggested.
class ProductDetailScreen extends StatefulWidget {
  final int productId;
  const ProductDetailScreen({super.key, required this.productId});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  ProductDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ApiClient.instance.getProductDetail(widget.productId);
      if (!mounted) return;
      setState(() => _detail = detail);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) return _gone();
      setState(() => _error = 'Could not load product: $e');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load product: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The product no longer exists: our team merged it into another (DAS-93).
  /// The list it was picked from is out of date, so it is fetched again and
  /// the shopkeeper picks again, rather than being shown an error.
  void _gone() {
    ProductCatalog.instance.noteMergedAway();
    context.say(ProductCatalog.mergedAwayMessage);
    Navigator.of(context).pop();
  }

  /// Opens the MRP editor for one batch (DAS-111) and, once the server has
  /// saved it, shows the new MRP here and refreshes the product list the
  /// sale screen prefills from.
  Future<void> _editMrp(ProductBatchInfo batch) async {
    final saved = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MrpSheet(productName: _detail!.name, batch: batch),
    );
    if (saved == null || !mounted) return;
    setState(() => _detail = _detail!.withBatch(batch.withMrp(saved)));
    unawaited(ProductCatalog.instance.refresh());
    context.say('MRP saved: ${rupees(saved)}');
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        title: detail == null
            ? const Text('Product')
            : ProductName(detail.name, qualifier: ProductCatalog.instance.index?.qualifier(detail.id)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: ErrorText(_error, padding: EdgeInsets.zero))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(Spacing.l),
                    children: [
                      Text(
                        '${qty(detail!.totalQuantity)} units total, across ${plural(detail.batches.length, 'batch', 'batches')}',
                        style: TextStyle(color: Theme.of(context).colorScheme.outline),
                      ),
                      const SizedBox(height: Spacing.m),
                      if (detail.batches.isEmpty) const Text('No batches in stock.'),
                      for (final b in detail.batches)
                        _BatchCard(b, onEditMrp: b.mrpEdited == null ? null : () => _editMrp(b)),
                    ],
                  ),
                ),
    );
  }
}

class _BatchCard extends StatelessWidget {
  final ProductBatchInfo batch;

  /// Null when the server cannot take an MRP edit: the button is not drawn.
  final VoidCallback? onEditMrp;
  const _BatchCard(this.batch, {this.onEditMrp});

  /// The rate/discount/free-goods scheme this batch was bought on, as one
  /// line — null when the server hasn't sent any of it (DAS-82, widened).
  static String? _dealLine(ProductBatchInfo b) {
    final parts = [
      if (b.rate != null) 'Rate ${rupees(b.rate!)}',
      if (b.discountPct != null) '${percent(b.discountPct!)} off',
      if (b.discountAmount != null && b.discountPct == null) '${rupees(b.discountAmount!)} off',
      if (b.freeQty != null && b.freeQty! > 0) '${qty(b.freeQty!)} free${b.freeScheme != null ? ' (${b.freeScheme})' : ''}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final b = batch;
    final colors = Theme.of(context).colorScheme;
    final purchase = b.sourceInvoiceId != null;
    final deal = _dealLine(b);
    return Card(
      child: InkWell(
        onTap: purchase
            ? () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => InvoiceDetailScreen(invoiceId: b.sourceInvoiceId!)),
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Batch ${b.batchNo ?? "—"}', style: const TextStyle(fontWeight: FontWeight.w500)),
                  if (b.isExpired)
                    Chip(
                      label: const Text('EXPIRED', style: TextStyle(fontSize: 11)),
                      backgroundColor: colors.errorContainer,
                      labelStyle: TextStyle(color: colors.onErrorContainer),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              Text('Expiry: ${b.expiryDate ?? "—"}'),
              Text('Quantity: ${qty(b.quantityOnHand)}'),
              if (b.mrp != null || onEditMrp != null)
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: Spacing.s,
                        children: [
                          if (b.mrp != null)
                            Text('MRP: ${rupees(b.mrp!)}')
                          else
                            const Text('MRP: not set', style: TextStyle(color: AppColors.accent)),
                          if (b.mrpEdited == true)
                            Text('edited', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.outline)),
                        ],
                      ),
                    ),
                    if (onEditMrp != null)
                      TextButton.icon(
                        onPressed: onEditMrp,
                        icon: const Icon(Icons.edit, size: 16),
                        label: Text(b.mrp == null ? 'Add MRP' : 'Edit MRP'),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                  ],
                ),
              Text('GST: ${percent(b.gstPct)}'),
              if (b.netRate != null) Text('Net rate: ${rupees(b.netRate!)}'),
              if (deal != null) Text(deal),
              if (b.vendorName != null || b.invoiceNo != null) ...[
                const SizedBox(height: Spacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          if (b.vendorName != null) 'Bought from ${b.vendorName}',
                          if (b.invoiceNo != null) 'Invoice ${b.invoiceNo}',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                    if (purchase) Icon(Icons.chevron_right, size: 18, color: colors.outline),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


/// The editor for one batch's MRP. Pops with the MRP the server saved, or
/// null if the shopkeeper backed out.
class _MrpSheet extends StatefulWidget {
  final String productName;
  final ProductBatchInfo batch;
  const _MrpSheet({required this.productName, required this.batch});

  @override
  State<_MrpSheet> createState() => _MrpSheetState();
}

class _MrpSheetState extends State<_MrpSheet> {
  static const _max = 1000000.0;
  late final TextEditingController _controller = TextEditingController(text: numText(widget.batch.mrp));
  String? _error;
  bool _busy = false;

  /// Set once the "below what you paid" warning has been shown: the next Save
  /// goes through.
  bool _warned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final mrp = double.tryParse(_controller.text.trim());
    if (mrp == null || mrp <= 0 || mrp > _max) {
      setState(() => _error = 'Enter an MRP above ₹0 and up to ${rupees(_max)}');
      return;
    }
    final paid = widget.batch.netRate;
    if (!_warned && paid != null && mrp < paid) {
      setState(() {
        _warned = true;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ApiClient.instance.setBatchMrp(widget.batch.id, mrp);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) {
        // Merged away by our team (DAS-93): the list this came from is old.
        ProductCatalog.instance.noteMergedAway();
        context.say(ProductCatalog.mergedAwayMessage);
        Navigator.of(context).pop();
        return;
      }
      setState(() => _error = e.errorCode == 'bad_mrp' ? 'That MRP is not allowed. Enter an amount above ₹0.' : 'Could not save: $e');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.batch;
    final colors = Theme.of(context).colorScheme;
    final where = [
      widget.productName,
      'Batch ${b.batchNo ?? "—"}',
      if (b.vendorName != null) b.vendorName!,
      if (b.invoiceNo != null) 'Invoice ${b.invoiceNo}',
    ].join(' · ');
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Spacing.l, Spacing.l, Spacing.l, MediaQuery.of(context).viewInsets.bottom + Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(b.mrp == null ? 'Add MRP' : 'Edit MRP', style: Theme.of(context).textTheme.titleMedium),
            Text(where, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
            const SizedBox(height: Spacing.m),
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {
                _warned = false;
                _error = null;
              }),
              decoration: InputDecoration(labelText: 'MRP (incl. GST)', errorText: _error),
            ),
            if (_warned)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.s),
                child: Text(
                  'This is below what you paid (net rate ${rupees(b.netRate!)}).',
                  style: const TextStyle(color: AppColors.accent),
                ),
              ),
            const SizedBox(height: Spacing.s),
            Text(
              'Only this batch changes. The purchase bill keeps what it printed, and past sales are not changed.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.m),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel'))),
                const SizedBox(width: Spacing.s),
                Expanded(
                  child: BusyFilledButton(busy: _busy, onPressed: _save, label: _warned ? 'Save anyway' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
