import 'package:flutter/material.dart';

/// Design tokens for the whole app — one file so a color/radius/spacing
/// value only ever needs changing in one place. Deliberately steers away
/// from generic Material blue: teal reads as "trustworthy, financial"
/// without colliding with the status badges used throughout capture/review
/// (blue = pending confirm, green = saved, amber = needs review, red =
/// failed) — those stay their own semantic colors, unrelated to branding.
class AppColors {
  AppColors._();

  // Medical/pharmacy — teal, as before.
  static const seedLight = Color(0xFF0F766E); // teal-700
  static const seedDark = Color(0xFF2DD4BF); // teal-400

  // Kirana/general store — same tonal position as the teal pair above, in red.
  static const seedLightKirana = Color(0xFFB91C1C); // red-700
  static const seedDarkKirana = Color(0xFFF87171); // red-400

  // Dark-theme accent + its deep/container tone, per business type — a
  // richer, more deliberate pine-green / brick-red than a plain Material 3
  // seed algorithm would generate, matching the app's actual design
  // reference rather than an approximation of it.
  static const pine = Color(0xFF13795F);
  static const pineDeep = Color(0xFF0B4F3F);
  static const brick = Color(0xFFB3453B);
  static const brickDeep = Color(0xFF7A2E28);

  // The one deliberately-light "spot" surface on an otherwise dark screen —
  // the capture empty-state illustration card, the login panel. Neutral
  // (cream/mint), not tied to business type — it reads as "paper", not brand.
  static const spotSurface = Color(0xFFEFF3EA);
  static const spotSurfaceOn = Color(0xFF16251F);

  static const accent = Color(0xFFD97706); // amber-600 — CTA highlight, used sparingly

  // Status semantics, shared by every batch/review/list screen so a badge
  // means the same thing everywhere it appears.
  static const statusSaved = Color(0xFF16A34A); // green-600
  static const statusPendingConfirm = Color(0xFF2563EB); // blue-600
  static const statusNeedsReview = Color(0xFFB45309); // amber-700
  static const statusFailed = Color(0xFFDC2626); // red-600
  static const statusReady = Color(0xFF64748B); // slate-500
}
