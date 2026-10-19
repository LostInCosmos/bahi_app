import 'package:flutter/material.dart';

/// A yes/no question. True when the shopkeeper chose [confirmLabel]; false
/// for [cancelLabel] or a tap outside. [destructive] colours the confirm
/// button red and leaves it a text button, so "Delete" never looks like the
/// default action.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
  bool barrierDismissible = true,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelLabel)),
        if (destructive)
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          )
        else
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return answer == true;
}

/// A message with one button to close it.
Future<void> showMessageDialog(BuildContext context, {required String title, required String message}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
