import 'package:flutter/material.dart';

/// One file a screen can export. A screen lists the files it offers and
/// [showExportOptions] lets the shopkeeper choose; another file type later is
/// one more entry in that list, not a change here.
class ExportOption {
  final String title;
  final String subtitle;
  final IconData icon;

  /// Runs once the sheet has closed, so the screen can show its own progress.
  final Future<void> Function() run;

  const ExportOption({required this.title, required this.subtitle, required this.run, this.icon = Icons.table_chart_outlined});
}

/// A modal sheet naming what is being exported ([heading]) and the files on
/// offer. Choosing one closes the sheet and runs it.
Future<void> showExportOptions(BuildContext context, {required String heading, required List<ExportOption> options}) async {
  final chosen = await showModalBottomSheet<ExportOption>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(heading, style: const TextStyle(fontWeight: FontWeight.w700))),
        for (final option in options)
          ListTile(
            leading: Icon(option.icon),
            title: Text(option.title),
            subtitle: Text(option.subtitle),
            onTap: () => Navigator.pop(context, option),
          ),
      ]),
    ),
  );
  if (chosen == null || !context.mounted) return;
  await chosen.run();
}
