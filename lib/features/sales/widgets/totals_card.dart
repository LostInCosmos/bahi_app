import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/inline_message.dart';

/// Subtotal, tax and total of a sale, as the receipt and the review screen
/// both show them. One card, so a sale reads the same before and after it is
/// made.
class SaleTotalsCard extends StatelessWidget {
  final double subtotal;
  final double tax;
  final double total;
  final String totalLabel;

  const SaleTotalsCard({
    super.key,
    required this.subtotal,
    required this.tax,
    required this.total,
    this.totalLabel = 'Total',
  });

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.m),
          child: Column(
            children: [
              KeyValueRow('Subtotal', rupees(subtotal)),
              KeyValueRow('CGST + SGST', rupees(tax)),
              const Divider(),
              KeyValueRow(totalLabel, rupees(total), bold: true),
            ],
          ),
        ),
      );
}
