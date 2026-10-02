import 'dart:async';

import 'package:flutter/material.dart';

/// Shown over a bill the server is retrying. Counts down to the next attempt
/// so the shopkeeper can see the bill is queued, not stuck.
class RetryLabel extends StatefulWidget {
  final int attempt;
  final int max;
  final DateTime at;
  const RetryLabel({super.key, required this.attempt, required this.max, required this.at});

  @override
  State<RetryLabel> createState() => _RetryLabelState();
}

class _RetryLabelState extends State<RetryLabel> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    // Repaint so the countdown moves; minute resolution needs nothing finer.
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  String _until() {
    final left = widget.at.difference(DateTime.now().toUtc());
    if (left.inSeconds <= 30) return 'retrying shortly';
    if (left.inMinutes < 1) return 'retrying in under a minute';
    return 'retrying in ${left.inMinutes + 1} min';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.refresh_rounded, color: Colors.white, size: 28),
        const SizedBox(height: 4),
        const Text(
          "Couldn't read it yet",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
        ),
        Text(
          '${_until()} · ${widget.attempt} of ${widget.max}',
          style: const TextStyle(color: Colors.white70, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
