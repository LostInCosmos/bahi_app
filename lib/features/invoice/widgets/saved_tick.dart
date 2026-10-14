import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';

/// A brief tick so a one-tap save does not look like a dropped tap. Shown
/// after every save now that nothing is asked first (DAS-71 removed the
/// supplier-GSTIN question from the shop), so it is the only acknowledgement.
Future<void> showSavedTick(BuildContext context) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      // Pops its OWN route rather than the root navigator's top: if this
      // dialog were ever already gone, popping the root would close the
      // screen out from under the save.
      Future<void>.delayed(const Duration(milliseconds: 850), () {
        if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      });
      return const Center(child: SavedTick());
    },
  );
}

/// The green tick shown when a bill saves without asking anything — the
/// verified-vendor path. Scales and fades in together so it reads as a
/// confirmation rather than a loading state, which is the whole point: that
/// path has no dialog, so without this the screen just closes.
class SavedTick extends StatefulWidget {
  const SavedTick({super.key});

  @override
  State<SavedTick> createState() => _SavedTickState();
}

class _SavedTickState extends State<SavedTick>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..forward();

  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    // Overshoots slightly and settles — a flat ease reads as a spinner frame.
    curve: Curves.elasticOut,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.4, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: _scale,
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(
                  color: Color(0xFF16A34A),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded,
                    color: Colors.white, size: 52),
              ),
              const SizedBox(height: Spacing.s),
              const Text(
                'Bill saved',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
