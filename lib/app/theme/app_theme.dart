import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_text_styles.dart';

export 'app_colors.dart';
export 'app_text_styles.dart';

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

/// Dark mode isn't the algorithmic Material 3 tonal palette you'd get from
/// ColorScheme.fromSeed — it's hand-specified to match the app's actual
/// design reference (a deep pine-green/near-black surface stack, not a
/// lightened-teal one). Light mode keeps the simpler seed-based scheme,
/// since the app is forced to dark theme in practice (see main.dart) and
/// light was never the one actually designed against.
ColorScheme _buildColorScheme({required Brightness brightness, required bool isKirana}) {
  if (brightness == Brightness.light) {
    final seed = isKirana ? AppColors.seedLightKirana : AppColors.seedLight;
    return ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
  }
  final accent = isKirana ? AppColors.brick : AppColors.pine;
  final accentDeep = isKirana ? AppColors.brickDeep : AppColors.pineDeep;
  return ColorScheme(
    brightness: Brightness.dark,
    primary: accent,
    onPrimary: Colors.white,
    primaryContainer: accentDeep,
    onPrimaryContainer: Colors.white,
    secondary: accent,
    onSecondary: Colors.white,
    secondaryContainer: Color.lerp(accentDeep, const Color(0xFF16251F), 0.4)!,
    onSecondaryContainer: Colors.white,
    tertiary: accent,
    onTertiary: Colors.white,
    tertiaryContainer: accentDeep,
    onTertiaryContainer: Colors.white,
    error: const Color(0xFFDC2626),
    onError: Colors.white,
    errorContainer: const Color(0xFF4A1616),
    onErrorContainer: const Color(0xFFFCA5A5),
    surface: const Color(0xFF0B1712),
    onSurface: const Color(0xFFEFF3EA),
    surfaceContainerLowest: const Color(0xFF070F0C),
    surfaceContainerLow: const Color(0xFF122019),
    surfaceContainer: const Color(0xFF16251F),
    surfaceContainerHigh: const Color(0xFF1C2E27),
    surfaceContainerHighest: const Color(0xFF223830),
    onSurfaceVariant: const Color(0xFF8CA79B),
    outline: const Color(0xFF3A4F47),
    outlineVariant: const Color(0xFF25362F),
    shadow: Colors.black,
    scrim: Colors.black54,
    inverseSurface: const Color(0xFFEFF3EA),
    onInverseSurface: const Color(0xFF16251F),
    inversePrimary: accentDeep,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildAppTheme({required Brightness brightness, String businessType = 'medical'}) {
  final isKirana = businessType == 'kirana';
  final colorScheme = _buildColorScheme(brightness: brightness, isKirana: isKirana);
  final base = ThemeData(colorScheme: colorScheme, useMaterial3: true, brightness: brightness);

  return base.copyWith(
    textTheme: buildTextTheme(base.textTheme),
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
      fillColor: colorScheme.surfaceContainerHigh,
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
      indicatorColor: colorScheme.primary,
      indicatorShape: const StadiumBorder(),
      elevation: 0,
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant, size: 22);
      }),
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
