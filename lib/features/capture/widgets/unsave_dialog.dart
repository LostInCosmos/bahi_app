import 'package:flutter/material.dart';

/// What to do about the stock a saved bill added when it goes back to Not
/// saved. Never assumed: the shopkeeper is asked every time, because inventory
/// is theirs to decide about.
enum UnsaveChoice { keepStock, removeStock }

/// Asks whether to move a saved bill back to Not saved, and whether to take
/// its stock out of inventory too. Null if they cancel.
Future<UnsaveChoice?> showUnsaveDialog(BuildContext context) {
  return showDialog<UnsaveChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Move back to Not saved?'),
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

/// The same question for a bill our team is still looking at (DAS-71). Its stock
/// always goes back with it, so nothing is asked about the stock — the dialog
/// only says so. True if they go ahead.
Future<bool> showUnsaveUnderReviewDialog(BuildContext context) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Move back to Not saved?'),
      content: const Text(
        'The bill stays as it was read and can be checked and saved again.\n\n'
        'The stock this bill added will be taken out of inventory.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('unsave-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('unsave-go'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Move back'),
        ),
      ],
    ),
  );
  return go == true;
}
