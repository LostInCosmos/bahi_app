import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../data/inventory_api.dart';
import '../data/product_catalog.dart';
import '../../invoice/presentation/invoice_detail_screen.dart';
import '../models/product.dart';

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

  /// The rate/discount/free-goods scheme this batch was bought on, as one
  /// line — null when the server hasn't sent any of it (DAS-82, widened).
  static String? _dealLine(ProductBatchInfo b) {
    final parts = [
      if (b.rate != null) 'Rate ₹${b.rate!.toStringAsFixed(2)}',
      if (b.discountPct != null) '${b.discountPct!.toStringAsFixed(b.discountPct == b.discountPct!.roundToDouble() ? 0 : 2)}% off',
      if (b.discountAmount != null && b.discountPct == null) '₹${b.discountAmount!.toStringAsFixed(2)} off',
      if (b.freeQty != null && b.freeQty! > 0)
        '${b.freeQty!.toStringAsFixed(0)} free${b.freeScheme != null ? ' (${b.freeScheme})' : ''}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

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
    unawaited(ProductCatalog.instance.refresh());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('That medicine was merged into another one. The list has been refreshed.')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_detail?.name ?? 'Product')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        '${_detail!.totalQuantity.toStringAsFixed(0)} units total, across '
                        '${_detail!.batches.length} batch${_detail!.batches.length == 1 ? '' : 'es'}',
                        style: TextStyle(color: Theme.of(context).colorScheme.outline),
                      ),
                      const SizedBox(height: 12),
                      if (_detail!.batches.isEmpty) const Text('No batches in stock.'),
                      ..._detail!.batches.map((b) {
                        final purchase = b.sourceInvoiceId != null;
                        return Card(
                          child: InkWell(
                            onTap: purchase
                                ? () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => InvoiceDetailScreen(invoiceId: b.sourceInvoiceId!),
                                      ),
                                    )
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('Batch ${b.batchNo ?? "—"}',
                                          style: const TextStyle(fontWeight: FontWeight.w500)),
                                      if (b.isExpired)
                                        Chip(
                                          label: const Text('EXPIRED', style: TextStyle(fontSize: 11)),
                                          backgroundColor: Theme.of(context).colorScheme.errorContainer,
                                          labelStyle:
                                              TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                                          visualDensity: VisualDensity.compact,
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text('Expiry: ${b.expiryDate ?? "—"}'),
                                  Text('Quantity: ${b.quantityOnHand.toStringAsFixed(0)}'),
                                  if (b.mrp != null) Text('MRP: ₹${b.mrp!.toStringAsFixed(2)}'),
                                  Text('GST: ${b.gstPct.toStringAsFixed(b.gstPct == b.gstPct.roundToDouble() ? 0 : 2)}%'),
                                  if (b.netRate != null) Text('Net rate: ₹${b.netRate!.toStringAsFixed(2)}'),
                                  if (_dealLine(b) != null) Text(_dealLine(b)!),
                                  if (b.vendorName != null || b.invoiceNo != null) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            [
                                              if (b.vendorName != null) 'Bought from ${b.vendorName}',
                                              if (b.invoiceNo != null) 'Invoice ${b.invoiceNo}',
                                            ].join(' · '),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                          ),
                                        ),
                                        if (purchase)
                                          Icon(Icons.chevron_right,
                                              size: 18, color: Theme.of(context).colorScheme.outline),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
    );
  }
}
