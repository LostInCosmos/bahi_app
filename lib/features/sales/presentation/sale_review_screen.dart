import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../inventory/data/product_catalog.dart';
import '../data/sale_api.dart';
import '../models/sale.dart';
import '../models/sale_totals.dart';
import '../widgets/cart_line_editor.dart';
import '../widgets/discount_field.dart';
import '../widgets/stock_note.dart';
import '../widgets/totals_card.dart';

/// Buyer GSTIN stays optional and out of the way — needed for a business
/// customer, irrelevant for the walk-in retail sale that's the common case.
///
/// Pops with the new sale's id on success, or null if the user backed out.
/// Either way `cart` (owned by [SalesScreen]) may have been mutated in place
/// by row removals and edits — the caller re-renders off the same list either way.
class SaleReviewScreen extends StatefulWidget {
  final List<CartEntry> cart;
  const SaleReviewScreen({super.key, required this.cart});

  @override
  State<SaleReviewScreen> createState() => _SaleReviewScreenState();
}

class _SaleReviewScreenState extends State<SaleReviewScreen> {
  final _buyerNameController = TextEditingController();
  final _buyerGstinController = TextEditingController();
  final _buyerPhoneController = TextEditingController();
  final _doctorController = TextEditingController();
  /// Cash unless the shopkeeper taps Online (the user, DAS-150).
  PaymentMode _paymentMode = PaymentMode.cash;
  /// The server's refusal of the phone or the doctor, under its field.
  String? _phoneError;
  String? _doctorError;
  final _saleDiscountController = TextEditingController();
  DiscountKind _saleDiscountKind = DiscountKind.amount;
  String? _message;
  bool _saving = false;

  @override
  void dispose() {
    _buyerNameController.dispose();
    _buyerGstinController.dispose();
    _buyerPhoneController.dispose();
    _doctorController.dispose();
    _saleDiscountController.dispose();
    super.dispose();
  }

  Discount? get _saleDiscount => parseDiscount(_saleDiscountController.text, _saleDiscountKind);

  /// Worked out once per build; the server decides the real numbers when the
  /// sale is saved, by the same rules (`sale_totals.dart`).
  SaleTotals get _totals => computeSale([for (final c in widget.cart) c.input], saleDiscount: _saleDiscount);

  static String _offLabel(Discount d) =>
      d.kind == DiscountKind.percentage ? '${percent(d.value)} off' : '${rupees(d.value)} off';

  /// Qty, price and the line's own discount, by the add sheet's rules. The
  /// line keeps its place; everything else on the screen stays as typed.
  Future<void> _edit(int index) async {
    final edited = await showCartLineEditor(context, widget.cart[index]);
    if (edited == null || !mounted) return;
    setState(() => widget.cart[index] = edited);
  }

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
      _phoneError = null;
      _doctorError = null;
    });
    try {
      final result = await ApiClient.instance.createSale(
        buyerName: _buyerNameController.text.trim(),
        buyerGstin: _buyerGstinController.text.trim(),
        buyerPhone: _buyerPhoneController.text.trim(),
        doctorName: _doctorController.text.trim(),
        paymentMode: _paymentMode,
        lineItems: widget.cart,
        discount: _saleDiscount,
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
      } else if (e.statusCode == 422 && detail is String && e.field == 'doctor_name') {
        setState(() => _doctorError = detail);
      } else if (e.statusCode == 422 &&
          detail is String &&
          (e.field == 'buyer_phone' || (e.field == null && detail.toLowerCase().contains('phone')))) {
        setState(() => _phoneError = detail);
      } else if (detail is Map && detail['error'] == 'bad_discount') {
        setState(() => _message = 'The discount is more than the amount it is taken from. Check it and try again.');
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
    final totals = _totals;
    return Scaffold(
      appBar: AppBar(title: const Text('Review sale')),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.l),
        children: [
          for (var i = 0; i < widget.cart.length; i++) _cartRow(context, i, totals),
          const SizedBox(height: Spacing.s),
          DiscountField(
            label: 'Discount on whole sale',
            controller: _saleDiscountController,
            kind: _saleDiscountKind,
            onKindChanged: (k) => setState(() => _saleDiscountKind = k),
            onChanged: () => setState(() {}),
            errorText: totals.saleError,
          ),
          const SizedBox(height: Spacing.m),
          Text('Paid by', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Spacing.xs),
          SegmentedButton<PaymentMode>(
            key: const ValueKey('payment-mode'),
            segments: [
              for (final m in PaymentMode.values) ButtonSegment(value: m, label: Text(m.label)),
            ],
            selected: {_paymentMode},
            onSelectionChanged: (s) => setState(() => _paymentMode = s.first),
          ),
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _buyerNameController,
            decoration: const InputDecoration(labelText: 'Buyer name (optional)'),
          ),
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _buyerPhoneController,
            keyboardType: TextInputType.phone,
            onChanged: (_) {
              if (_phoneError != null) setState(() => _phoneError = null);
            },
            decoration: InputDecoration(labelText: 'Customer phone (optional)', errorText: _phoneError),
          ),
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _doctorController,
            textCapitalization: TextCapitalization.words,
            maxLength: 200,
            onChanged: (_) {
              if (_doctorError != null) setState(() => _doctorError = null);
            },
            decoration: InputDecoration(
                labelText: 'Prescribed by (optional)', hintText: "Doctor's name", counterText: '', errorText: _doctorError),
          ),
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _buyerGstinController,
            decoration: const InputDecoration(labelText: 'Buyer GSTIN (optional — leave blank for a retail sale)'),
          ),
          const SizedBox(height: Spacing.m),
          SaleTotalsCard(
            items: totals.items,
            itemDiscounts: totals.itemDiscounts,
            saleDiscount: totals.saleDiscount,
            tax: totals.tax,
            total: totals.grandTotal,
          ),
          ErrorText(_message),
          const SizedBox(height: Spacing.l),
          BusyFilledButton(
            busy: _saving,
            onPressed: widget.cart.isEmpty || totals.hasError ? null : _complete,
            label: 'Complete sale',
          ),
        ],
      ),
    );
  }

  /// A line: what it comes to after its own discount, with the undiscounted
  /// amount struck through and the discount as typed beneath.
  Widget _cartRow(BuildContext context, int i, SaleTotals totals) {
    final c = widget.cart[i];
    final line = totals.lines[i];
    final off = line.itemDiscountPaise > 0 && c.discount != null;
    return Card(
      child: ListTile(
        onTap: () => _edit(i),
        title: Text('${c.productName} × ${qty(c.qty)}'),
        subtitle: c.shortStockNote == null
            ? Text('Batch ${c.batchNo ?? "—"}')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text('Batch ${c.batchNo ?? "—"}'), StockNote(c.shortStockNote!)],
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (off)
                  Text(
                    rupees(line.gross),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          decoration: TextDecoration.lineThrough,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                Text(rupees(off ? line.gross - line.itemDiscount : line.gross)),
                if (off) Text(_offLabel(c.discount!), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Edit', onPressed: () => _edit(i)),
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Remove', onPressed: () => _remove(i)),
          ],
        ),
      ),
    );
  }
}
