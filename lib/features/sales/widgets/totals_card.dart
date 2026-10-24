import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/inline_message.dart';

/// What a sale comes to, as the checkout screen and the receipt both show it:
/// the items, what was taken off, the total, and the GST that is inside that
/// total (the price a shop types is GST-inclusive — DAS-111). One card, so a
/// sale reads the same before and after it is made.
class SaleTotalsCard extends StatelessWidget {
  /// What the lines add up to before any discount.
  final double items;
  final double itemDiscounts;
  final double saleDiscount;

  /// The GST inside [total]; [cgst] and [sgst] (the receipt) split it.
  final double tax;
  final double? cgst;
  final double? sgst;
  final double total;
  final String totalLabel;

  const SaleTotalsCard({
    super.key,
    required this.items,
    this.itemDiscounts = 0,
    this.saleDiscount = 0,
    required this.tax,
    this.cgst,
    this.sgst,
    required this.total,
    this.totalLabel = 'Total',
  });

  @override
  Widget build(BuildContext context) {
    final discounted = itemDiscounts > 0 || saleDiscount > 0;
    final split = cgst != null && sgst != null ? ' (CGST ${rupees(cgst!)} + SGST ${rupees(sgst!)})' : '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.m),
        child: Column(
          children: [
            if (discounted) KeyValueRow('Items', rupees(items)),
            if (itemDiscounts > 0) KeyValueRow('Item discounts', '−${rupees(itemDiscounts)}'),
            if (saleDiscount > 0) KeyValueRow('Discount (whole sale)', '−${rupees(saleDiscount)}'),
            if (discounted) const Divider(),
            KeyValueRow(totalLabel, rupees(total), bold: true),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Includes GST ${rupees(tax)}$split',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
