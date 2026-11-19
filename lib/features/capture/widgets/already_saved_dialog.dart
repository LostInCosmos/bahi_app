import 'package:flutter/material.dart';

enum AlreadySavedAction { view, discard }

/// What a duplicate Save shows (DAS-193; the user chose this dialog, with
/// "Close", 2026-11-16; the web shows the same). [message] is the server's
/// "Bill A029022 of 22 Oct 2026 is already saved." Returns null for Close
/// or a dismissed dialog: nothing changes, and the copy stays Not saved.
Future<AlreadySavedAction?> showAlreadySavedDialog(BuildContext context, String message, {bool canView = true}) {
  return showDialog<AlreadySavedAction>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return AlertDialog(
        title: const Text('Already saved'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 8),
            Text(
              'This photo is a second copy of it. Saving it again would count its stock and GST twice.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: colors.error, side: BorderSide(color: colors.error)),
            onPressed: () => Navigator.pop(context, AlreadySavedAction.discard),
            child: const Text('Discard this copy'),
          ),
          // Hidden when the server names no saved bill (as on the web).
          if (canView)
            FilledButton(
              onPressed: () => Navigator.pop(context, AlreadySavedAction.view),
              child: const Text('View saved bill'),
            ),
        ],
      );
    },
  );
}
