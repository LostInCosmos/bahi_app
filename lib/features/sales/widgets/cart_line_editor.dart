import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/inline_message.dart';
import '../models/sale.dart';
import '../models/sale_totals.dart';
import 'discount_field.dart';
import 'stock_note.dart';

/// Changes one line of the cart from the review screen: its quantity, price
/// and discount, by the same rules as the batch picker that added it. The
/// batch is not changed here — stock and expiry belong to it, so a different
/// batch is a line of its own. Returns the edited line, or null on Cancel.
Future<CartEntry?> showCartLineEditor(BuildContext context, CartEntry entry) =>
    showModalBottomSheet<CartEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CartLineEditor(entry: entry),
    );

class _CartLineEditor extends StatefulWidget {
  final CartEntry entry;
  const _CartLineEditor({required this.entry});

  @override
  State<_CartLineEditor> createState() => _CartLineEditorState();
}

class _CartLineEditorState extends State<_CartLineEditor> {
  late final _qty = TextEditingController(text: numText(widget.entry.qty));
  late final _rate = TextEditingController(text: numText(widget.entry.rate));
  late final _discount = TextEditingController(text: numText(widget.entry.discount?.value));
  late DiscountKind _discountKind = widget.entry.discount?.kind ?? DiscountKind.percentage;

  @override
  void dispose() {
    _qty.dispose();
    _rate.dispose();
    _discount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final available = e.available;
    final quantity = double.tryParse(_qty.text) ?? 0;
    final rate = double.tryParse(_rate.text) ?? 0;
    final discount = parseDiscount(_discount.text, _discountKind);
    final totals = computeSale([SaleLineInput(qty: quantity, rate: rate, gstPct: e.gstPct, discount: discount)]);

    // More than the batch holds is allowed, with a note (DAS-111); none is not.
    final qtyError = quantity <= 0 ? 'Enter a quantity above 0' : null;
    final note = qtyError == null ? stockNote(quantity, available) : null;
    final priceError = rate <= 0 ? 'Enter a price above ₹0' : null;
    // With no price there is no line to take a discount off yet.
    final discountError = rate > 0 ? totals.itemErrors[0] : null;
    final valid = qtyError == null && priceError == null && discountError == null;
    final off = valid && discount != null && totals.itemDiscounts > 0;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Spacing.l, Spacing.l, Spacing.l, MediaQuery.viewInsetsOf(context).bottom + Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.productName, style: Theme.of(context).textTheme.titleMedium),
            Text(
              [
                'Batch ${e.batchNo ?? "—"}',
                if (available != null) '${qty(available)} in stock',
              ].join(' · '),
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: Spacing.m),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _qty,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    // The reason is written under the row: the field is too
                    // narrow for it. The red outline stays on the field.
                    decoration: InputDecoration(
                        labelText: 'Qty', error: qtyError == null ? null : const SizedBox.shrink()),
                  ),
                ),
                const SizedBox(width: Spacing.s),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _rate,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        labelText: 'Price (incl. GST)', error: priceError == null ? null : const SizedBox.shrink()),
                  ),
                ),
              ],
            ),
            ErrorText(qtyError ?? priceError, padding: const EdgeInsets.only(top: Spacing.xs)),
            if (note != null) StockNote(note),
            const SizedBox(height: Spacing.m),
            DiscountField(
              label: 'Discount on this item',
              controller: _discount,
              kind: _discountKind,
              onKindChanged: (k) => setState(() => _discountKind = k),
              onChanged: () => setState(() {}),
              errorText: discountError,
            ),
            if (valid)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.s),
                child: Text(
                  off
                      ? 'Line total ${rupees(totals.grandTotal)}  (${rupees(totals.itemDiscounts)} off)'
                      : 'Line total ${rupees(totals.grandTotal)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: Spacing.m),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: Spacing.s),
                Expanded(
                  child: FilledButton(
                    onPressed: valid
                        ? () => Navigator.pop(
                              context,
                              e.edited(qty: quantity, rate: rate, discount: off ? discount : null),
                            )
                        : null,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
