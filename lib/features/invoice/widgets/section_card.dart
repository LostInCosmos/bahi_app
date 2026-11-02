import 'package:flutter/material.dart';
import '../../../app/theme/app_theme.dart';

/// Groups a chunk of the form under a titled card with a leading icon —
/// splits the review form into scannable sections (seller, invoice, totals)
/// instead of one long undifferentiated list of fields.
class SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const SectionCard({super.key, required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: Spacing.xs),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: Spacing.m),
            ...children,
          ],
        ),
      ),
    );
  }
}
