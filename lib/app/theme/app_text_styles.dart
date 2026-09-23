import 'package:flutter/material.dart';

// Public (not private) despite the original single-file version being
// private — buildAppTheme() in app_theme.dart calls this from a different
// library file now, and Dart's `export` doesn't re-export private symbols,
// so a leading underscore here would make it uncallable from there.
TextTheme buildTextTheme(TextTheme base) {
  return base.copyWith(
    displaySmall: base.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
    headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
    headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
    titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
    titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
    bodyLarge: base.bodyLarge?.copyWith(height: 1.4),
    bodyMedium: base.bodyMedium?.copyWith(height: 1.4),
  );
}

/// A distinct style for money figures wherever they appear (grand totals,
/// list amounts) — tabular figures so a column of numbers lines up, and a
/// bit heavier than surrounding body text so the number a shopkeeper
/// actually cares about is the thing the eye lands on first.
TextStyle amountTextStyle(BuildContext context, {bool emphasized = false}) {
  final base = Theme.of(context).textTheme.titleMedium!;
  return base.copyWith(
    fontWeight: emphasized ? FontWeight.w800 : FontWeight.w700,
    fontFeatures: const [FontFeature.tabularFigures()],
    fontSize: emphasized ? 20 : null,
  );
}
