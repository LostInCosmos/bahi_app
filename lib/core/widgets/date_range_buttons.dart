import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../utils/format.dart';

/// Two side-by-side date buttons, "From" and "To", each opening a picker.
/// Purchases and Sales history both had this, with their own copies of the
/// picker logic; now the screen holds two `DateTime?`s and this does the rest.
class DateRangeButtons extends StatelessWidget {
  final DateTime? start;
  final DateTime? end;
  final String startLabel;
  final String endLabel;
  final void Function(DateTime? start, DateTime? end) onChanged;

  const DateRangeButtons({
    super.key,
    required this.start,
    required this.end,
    required this.onChanged,
    this.startLabel = 'From',
    this.endLabel = 'To',
  });

  Future<void> _pick(BuildContext context, {required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? start : end) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    onChanged(isStart ? picked : start, isStart ? end : picked);
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pick(context, isStart: true),
              child: Text(isoDate(start) ?? startLabel),
            ),
          ),
          const SizedBox(width: Spacing.s),
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pick(context, isStart: false),
              child: Text(isoDate(end) ?? endLabel),
            ),
          ),
        ],
      );
}
