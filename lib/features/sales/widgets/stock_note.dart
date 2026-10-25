import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// The amber note under a quantity the batch does not hold (DAS-111): a
/// warning to the shopkeeper, not an error, and never on the bill.
class StockNote extends StatelessWidget {
  final String text;
  const StockNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Spacing.xs),
        // amber-700 is too dark to read on the dark theme: amber-300 there.
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFFFCD34D)
                    : AppColors.statusNeedsReview)),
      );
}
