import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../models/sale_totals.dart';

/// What is typed in a discount field, as a [Discount]: null when empty, a NaN
/// value when it is not a number (so the maths reports it, not this widget).
Discount? parseDiscount(String text, DiscountKind kind) {
  final t = text.trim();
  if (t.isEmpty) return null;
  return Discount(kind, double.tryParse(t) ?? double.nan);
}

/// A discount entry: a number and a ₹ / % toggle beside it. Used per item in
/// the batch picker and for the whole sale at checkout (DAS-111).
class DiscountField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final DiscountKind kind;
  final ValueChanged<DiscountKind> onKindChanged;
  final VoidCallback onChanged;
  final String? errorText;

  const DiscountField({
    super.key,
    required this.label,
    required this.controller,
    required this.kind,
    required this.onKindChanged,
    required this.onChanged,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                labelText: label,
                errorText: errorText,
                suffixText: kind == DiscountKind.percentage ? '%' : '₹',
              ),
            ),
          ),
          const SizedBox(width: Spacing.s),
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: SegmentedButton<DiscountKind>(
              segments: const [
                ButtonSegment(value: DiscountKind.amount, label: Text('₹')),
                ButtonSegment(value: DiscountKind.percentage, label: Text('%')),
              ],
              selected: {kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => onKindChanged(s.first),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
        ],
      );
}
