import 'package:flutter/material.dart';

/// What to do about the stock a saved bill added when it goes back to Check &
/// save. Never assumed: the shopkeeper is asked every time, because inventory
/// is theirs to decide about.
enum UnsaveChoice { keepStock, removeStock }

/// Asks whether to move a saved bill back to Check & save, and whether to take
/// its stock out of inventory too. Null if they cancel.
Future<UnsaveChoice?> showUnsaveDialog(BuildContext context) {
  return showDialog<UnsaveChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Move back to Check & save?'),
      content: const Text(
        'The bill stays as it was read and can be checked and saved again.\n\n'
        'Do you also want to take the stock this bill added out of inventory?',
      ),
      actions: [
        TextButton(
          key: const ValueKey('unsave-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          key: const ValueKey('unsave-keep'),
          onPressed: () => Navigator.pop(context, UnsaveChoice.keepStock),
          child: const Text('Keep stock'),
        ),
        FilledButton(
          key: const ValueKey('unsave-remove'),
          onPressed: () => Navigator.pop(context, UnsaveChoice.removeStock),
          child: const Text('Remove stock'),
        ),
      ],
    ),
  );
}
