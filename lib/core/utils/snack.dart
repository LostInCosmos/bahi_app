import 'package:flutter/material.dart';

/// Telling the shopkeeper something in passing.
extension Snack on BuildContext {
  /// One message at a time: whatever is showing is replaced, not queued
  /// behind, so a burst of outcomes does not leave the screen reading stale
  /// news for a minute. Safe to call from an unmounted context: it does nothing.
  void say(String message, {SnackBarAction? action, Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: action,
        duration: duration ?? const Duration(milliseconds: 4000),
      ));
  }
}
