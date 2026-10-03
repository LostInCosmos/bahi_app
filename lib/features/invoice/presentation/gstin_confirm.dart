import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../models/invoice.dart';

// The GSTIN confirmation step and the "saved" tick, shared by every screen
// that saves a bill. There are two: the review screen, and the one-tap
// confirm on the capture grid for bills that extracted cleanly. Only the
// first had this at first, so the second showed the server's raw
// `gstin_confirmation_required` JSON and marked the bill failed — and its
// Retry re-ran extraction, a fresh LLM call that then failed the same way.

/// One look at this bill's GSTIN before it is saved, with the photo above
/// it so it can be read off the paper (pinch to zoom — these are faint
/// dot-matrix prints).
///
/// Pre-filled, so the usual answer is a single tap on Submit. For a
/// supplier already in the table the pre-fill is the identity we hold,
/// which beats a fresh misread; for a new one it is what was read off this
/// bill. Asked once per supplier, not once per bill — once a vendor is
/// verified this stops appearing (ADR-008).
///
/// Returns the confirmed GSTIN, or null if they backed out.
Future<String?> showGstinConfirmDialog(
  BuildContext context,
  VendorHint hint, {
  Uint8List? photo,
  String fallbackName = '',
}) async {
  final controller = TextEditingController(text: hint.gstin);
  final bytes = photo;
  final name = hint.vendorName.isEmpty ? fallbackName : hint.vendorName;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) {
        final value = controller.text.trim().toUpperCase();
        final valid =
            RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$')
                .hasMatch(value);
        final changed = value != hint.gstin.toUpperCase();
        return AlertDialog(
          title: Text(hint.vendorKnown ? 'Check the supplier' : 'New supplier',
              textAlign: TextAlign.center),
          actionsAlignment: MainAxisAlignment.center,
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  textAlign: TextAlign.center,
                  hint.vendorKnown
                      ? (name.isEmpty
                          ? 'Please check this GSTIN against the bill before saving.'
                          : 'Please check $name\'s GSTIN against the bill before saving.')
                      : (name.isEmpty
                          ? "We haven't seen this supplier before. Please check their GSTIN against the bill."
                          : "We haven't seen $name before. Please check their GSTIN against the bill."),
                ),
                const SizedBox(height: Spacing.s),
                if (bytes != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        color: Colors.black,
                        child: InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 8,
                          child: Image.memory(bytes, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                if (bytes != null)
                  const Padding(
                    padding: EdgeInsets.only(top: Spacing.xs),
                    child: Text('Pinch to zoom',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11)),
                  ),
                const SizedBox(height: Spacing.s),
                TextField(
                  controller: controller,
                  // Not autofocused: the point is to READ it, and a keyboard
                  // over the photo is the opposite of that. It is still
                  // editable on tap for the times it is wrong.
                  maxLength: 15,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 18,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600),
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'GSTIN',
                    floatingLabelAlignment: FloatingLabelAlignment.center,
                    counterText: '',
                    hintText: '09ABCDE1234F1Z5',
                    errorText: value.isEmpty || valid
                        ? null
                        : 'Needs 15 characters in the GSTIN format',
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                if (changed && hint.vendorKnown)
                  const Padding(
                    padding: EdgeInsets.only(top: Spacing.xs),
                    child: Text(
                      'This will correct the supplier\'s saved GSTIN.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Color(0xFFB45309)),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: valid ? () => Navigator.of(context).pop(value) : null,
              child: const Text('Submit'),
            ),
          ],
        );
      },
    ),
  );
}

/// A brief tick so a one-tap save does not look like a dropped tap. Only
/// shown on the path where nothing was asked — after the confirmation
/// dialog the Submit press is itself the acknowledgement.
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
