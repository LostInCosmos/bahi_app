import 'package:flutter/material.dart';

/// Design tokens for the whole app — one file so a color/radius/spacing
/// value only ever needs changing in one place. Deliberately steers away
/// from generic Material blue: teal reads as "trustworthy, financial"
/// without colliding with the status badges used throughout capture/review
/// (blue = pending confirm, green = saved, amber = needs review, red =
/// failed) — those stay their own semantic colors, unrelated to branding.
class AppColors {
  AppColors._();

  static const seedLight = Color(0xFF0F766E); // teal-700
  static const seedDark = Color(0xFF2DD4BF); // teal-400
  static const accent = Color(0xFFD97706); // amber-600 — CTA highlight, used sparingly

  // Status semantics, shared by every batch/review/list screen so a badge
  // means the same thing everywhere it appears.
  static const statusSaved = Color(0xFF16A34A); // green-600
  static const statusPendingConfirm = Color(0xFF2563EB); // blue-600
  static const statusNeedsReview = Color(0xFFB45309); // amber-700
  static const statusFailed = Color(0xFFDC2626); // red-600
  static const statusReady = Color(0xFF64748B); // slate-500
}

class Spacing {
  Spacing._();
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

class AppRadius {
  AppRadius._();
  static const card = 20.0;
  static const control = 14.0;
  static const chip = 100.0;
}

TextTheme _buildTextTheme(TextTheme base) {
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

ThemeData buildAppTheme({required Brightness brightness}) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: brightness == Brightness.light ? AppColors.seedLight : AppColors.seedDark,
    brightness: brightness,
  );
  final base = ThemeData(colorScheme: colorScheme, useMaterial3: true, brightness: brightness);

  return base.copyWith(
    textTheme: _buildTextTheme(base.textTheme),
    scaffoldBackgroundColor: colorScheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.l, vertical: Spacing.m),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.l, vertical: Spacing.m),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
        side: BorderSide(color: colorScheme.outlineVariant),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      contentPadding: const EdgeInsets.symmetric(horizontal: Spacing.l, vertical: Spacing.m),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: colorScheme.error, width: 1.5),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colorScheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colorScheme.primaryContainer,
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
        );
      }),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
      side: BorderSide.none,
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _FadeThroughTransitionsBuilder(),
        TargetPlatform.iOS: _FadeThroughTransitionsBuilder(),
        TargetPlatform.linux: _FadeThroughTransitionsBuilder(),
        TargetPlatform.macOS: _FadeThroughTransitionsBuilder(),
        TargetPlatform.windows: _FadeThroughTransitionsBuilder(),
      },
    ),
  );
}

/// A subtler alternative to the default slide transition — a soft
/// fade+scale that feels calmer for a form-heavy business app pushing a lot
/// of full-screen routes (crop -> review -> detail).
class _FadeThroughTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeThroughTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}
