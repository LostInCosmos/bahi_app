import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

/// An error line under a form or a list — the theme's error colour, with the
/// padding every screen used to add by hand. Nothing when [message] is null,
/// so a screen writes `ErrorText(_error)` and lets it decide.
class ErrorText extends StatelessWidget {
  final String? message;
  final EdgeInsetsGeometry padding;
  final TextAlign? textAlign;

  const ErrorText(this.message, {super.key, this.padding = const EdgeInsets.only(top: Spacing.m), this.textAlign});

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: textAlign),
    );
  }
}

/// What a list shows when it has nothing: an outline icon over a quiet line
/// of text, the same on every tab.
class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final EdgeInsetsGeometry padding;

  const EmptyHint({
    super.key,
    required this.icon,
    required this.text,
    this.padding = const EdgeInsets.only(top: Spacing.xxl),
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Column(children: [
        Icon(icon, size: 48, color: colors.outline),
        const SizedBox(height: Spacing.s),
        Text(text, style: TextStyle(color: colors.onSurfaceVariant), textAlign: TextAlign.center),
      ]),
    );
  }
}

/// A screen whose one load failed: the reason and a Try again button, and
/// nothing else — never a form of empty fields over it, which a Save could
/// send (the account screen once could). [message] null shows a generic line.
class LoadFailed extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const LoadFailed(this.message, {super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ErrorText(message ?? 'Could not load this.', padding: EdgeInsets.zero, textAlign: TextAlign.center),
              const SizedBox(height: Spacing.m),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            ],
          ),
        ),
      );
}

/// A label on the left, a value on the right — one line of a detail screen
/// or a totals card.
class KeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;

  const KeyValueRow(this.label, this.value, {super.key, this.bold = false});

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.bold) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
              child: Text(label, style: style ?? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Text(value, style: style),
        ],
      ),
    );
  }
}

/// A heading above a group of [KeyValueRow]s.
class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Spacing.s),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}
