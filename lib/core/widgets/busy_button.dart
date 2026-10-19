import 'package:flutter/material.dart';

/// The small spinner a button shows in place of its label or icon while its
/// action runs. One widget, so every busy button in the app is the same size
/// and stroke; it used to be a `SizedBox(CircularProgressIndicator)` written
/// out some fourteen times, not always identically.
class ButtonSpinner extends StatelessWidget {
  /// Side of the spinner, in dp. 16 fits a button's icon slot.
  final double size;

  /// On a filled button the spinner is white, on an outlined one it takes the
  /// theme's colour.
  final bool onFilled;

  const ButtonSpinner({super.key, this.size = 16, this.onFilled = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: size,
        width: size,
        child: CircularProgressIndicator(strokeWidth: 2, color: onFilled ? Colors.white : null),
      );
}

/// A filled button that shows [ButtonSpinner] while [busy], and cannot be
/// tapped again until it is done. [label] is the resting text; [busyLabel],
/// when given, replaces it while busy ("Saving…").
class BusyFilledButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;
  final String label;
  final String? busyLabel;
  final IconData? icon;

  const BusyFilledButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.label,
    this.busyLabel,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final press = busy ? null : onPressed;
    if (icon == null) {
      return FilledButton(
        onPressed: press,
        child: busy ? const ButtonSpinner(onFilled: true) : Text(label),
      );
    }
    return FilledButton.icon(
      onPressed: press,
      icon: busy ? const ButtonSpinner(onFilled: true) : Icon(icon),
      label: Text(busy ? (busyLabel ?? label) : label),
    );
  }
}

/// The outlined counterpart of [BusyFilledButton].
class BusyOutlinedButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;
  final String label;
  final String? busyLabel;
  final IconData? icon;
  final ButtonStyle? style;

  const BusyOutlinedButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.label,
    this.busyLabel,
    this.icon,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final press = busy ? null : onPressed;
    if (icon == null) {
      return OutlinedButton(
        onPressed: press,
        style: style,
        child: busy ? const ButtonSpinner() : Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: press,
      style: style,
      icon: busy ? const ButtonSpinner() : Icon(icon, size: 18),
      label: Text(busy ? (busyLabel ?? label) : label),
    );
  }
}
