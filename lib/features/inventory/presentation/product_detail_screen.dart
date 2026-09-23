import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
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
    } catch (e) {
      setState(() => _error = 'Could not load product: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
                      ..._detail!.batches.map((b) => Card(
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
                                ],
                              ),
                            ),
                          )),
                    ],
                  ),
                ),
    );
  }
}
