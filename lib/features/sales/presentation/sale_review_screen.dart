import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../models/sale.dart';

/// Buyer GSTIN stays optional and out of the way — needed for a business
/// customer, irrelevant for the walk-in retail sale that's the common case.
///
/// Pops with the new sale's id on success, or null if the user backed out.
/// Either way `cart` (owned by [SalesScreen]) may have been mutated in place
/// by row removals — the caller re-renders off the same list either way.
class SaleReviewScreen extends StatefulWidget {
  final List<CartEntry> cart;
  const SaleReviewScreen({super.key, required this.cart});

  @override
  State<SaleReviewScreen> createState() => _SaleReviewScreenState();
}

class _SaleReviewScreenState extends State<SaleReviewScreen> {
  final _buyerNameController = TextEditingController();
  final _buyerGstinController = TextEditingController();
  String? _message;
  bool _saving = false;

  @override
  void dispose() {
    _buyerNameController.dispose();
    _buyerGstinController.dispose();
    super.dispose();
  }

  double get _subtotal => widget.cart.fold(0.0, (sum, c) => sum + c.lineAmount);
  double get _totalTax => widget.cart.fold(0.0, (sum, c) => sum + c.lineAmount * c.gstPct / 100);

  void _remove(int index) {
    setState(() => widget.cart.removeAt(index));
    if (widget.cart.isEmpty) Navigator.of(context).pop();
  }

  Future<void> _complete() async {
    if (_saving || widget.cart.isEmpty) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final result = await ApiClient.instance.createSale(
        buyerName: _buyerNameController.text.trim(),
        buyerGstin: _buyerGstinController.text.trim(),
        lineItems: widget.cart,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result['sale_id'] as int);
    } on ApiException catch (e) {
      final detail = e.detail;
      if (!mounted) return;
      if (detail is Map && detail['error'] == 'insufficient_stock') {
        setState(() => _message = 'Not enough stock for ${detail['product_name']}: '
            'requested ${detail['requested']}, available ${detail['available']}.');
      } else {
        setState(() => _message = 'Sale failed: $e');
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Sale failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review sale')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...widget.cart.asMap().entries.map((entry) {
            final i = entry.key;
            final c = entry.value;
            return Card(
              child: ListTile(
                title: Text('${c.productName} × ${c.qty.toStringAsFixed(0)}'),
                subtitle: Text('Batch ${c.batchNo ?? "—"}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('₹${c.lineAmount.toStringAsFixed(2)}'),
                    IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _remove(i)),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          TextField(
            controller: _buyerNameController,
            decoration: const InputDecoration(labelText: 'Buyer name (optional)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _buyerGstinController,
            decoration:
                const InputDecoration(labelText: 'Buyer GSTIN (optional — leave blank for a retail sale)'),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text('Subtotal'),
                    Text('₹${_subtotal.toStringAsFixed(2)}'),
                  ]),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text('CGST + SGST'),
                    Text('₹${_totalTax.toStringAsFixed(2)}'),
                  ]),
                  const Divider(),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('₹${(_subtotal + _totalTax).toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                ],
              ),
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: widget.cart.isEmpty || _saving ? null : _complete,
            child: _saving
                ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Complete sale'),
          ),
        ],
      ),
    );
  }
}
