import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../inventory/data/product_catalog.dart';
import '../data/sale_api.dart';
import '../models/sale.dart';
import '../widgets/totals_card.dart';

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

  /// How the server refuses a batch that no longer exists: `batch 12 not found`.
  static final _goneBatch = RegExp(r'batch (\d+) not found');

  /// A batch in the cart was merged into another by our team (DAS-93) after it
  /// was picked. Its line comes out of the cart, the product list is fetched
  /// again, and the shopkeeper adds it again — nothing else in the cart changes.
  void _dropGoneBatch(int batchId) {
    final gone = widget.cart.where((c) => c.productBatchId == batchId).map((c) => c.productName).toSet();
    ProductCatalog.instance.noteMergedAway();
    setState(() {
      widget.cart.removeWhere((c) => c.productBatchId == batchId);
      _message = '${gone.isEmpty ? 'A medicine' : gone.join(', ')} was merged into another by our team and '
          'has been taken out of the cart. Add it again from the list.';
    });
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
      final gone = e.statusCode == 404 ? _goneBatch.firstMatch(e.message) : null;
      if (detail is Map && detail['error'] == 'insufficient_stock') {
        setState(() => _message = 'Not enough stock for ${detail['product_name']}: '
            'requested ${detail['requested']}, available ${detail['available']}.');
      } else if (gone != null) {
        _dropGoneBatch(int.parse(gone.group(1)!));
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
        padding: const EdgeInsets.all(Spacing.l),
        children: [
          for (var i = 0; i < widget.cart.length; i++)
            Card(
              child: ListTile(
                title: Text('${widget.cart[i].productName} × ${qty(widget.cart[i].qty)}'),
                subtitle: Text('Batch ${widget.cart[i].batchNo ?? "—"}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(rupees(widget.cart[i].lineAmount)),
                    IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _remove(i)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _buyerNameController,
            decoration: const InputDecoration(labelText: 'Buyer name (optional)'),
          ),
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _buyerGstinController,
            decoration: const InputDecoration(labelText: 'Buyer GSTIN (optional — leave blank for a retail sale)'),
          ),
          const SizedBox(height: Spacing.m),
          SaleTotalsCard(subtotal: _subtotal, tax: _totalTax, total: _subtotal + _totalTax),
          ErrorText(_message),
          const SizedBox(height: Spacing.l),
          BusyFilledButton(
            busy: _saving,
            onPressed: widget.cart.isEmpty ? null : _complete,
            label: 'Complete sale',
          ),
        ],
      ),
    );
  }
}
