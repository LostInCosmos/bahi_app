import 'dart:async';
import 'package:flutter/material.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/busy_button.dart';
import '../../sales/presentation/sale_receipt_screen.dart';
import '../data/voice_api.dart';

/// Wraps the existing (unmodified) [SaleReceiptScreen] with a 30-second
/// "Undo" banner — voice sales are the one flow where a misheard line can
/// slip all the way to a confirmed sale, so a brief undo window matters more
/// here than on the manual sell flow.
class VoiceSaleReceiptWithUndo extends StatefulWidget {
  final int saleId;
  final int voiceOrderId;
  const VoiceSaleReceiptWithUndo({super.key, required this.saleId, required this.voiceOrderId});

  @override
  State<VoiceSaleReceiptWithUndo> createState() => _VoiceSaleReceiptWithUndoState();
}

class _VoiceSaleReceiptWithUndoState extends State<VoiceSaleReceiptWithUndo> {
  static const _undoWindow = 30;
  int _secondsLeft = _undoWindow;
  Timer? _timer;
  bool _undoing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft <= 1) {
        t.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _undo() async {
    if (_undoing) return;
    setState(() => _undoing = true);
    try {
      await ApiClient.instance.undoVoiceOrder(widget.voiceOrderId);
      if (!mounted) return;
      Navigator.of(context).pop('undone');
    } catch (e) {
      if (!mounted) return;
      context.say('Could not undo: $e');
      setState(() => _undoing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SaleReceiptScreen(saleId: widget.saleId),
        if (_secondsLeft > 0)
          Positioned(
            left: Spacing.l,
            right: Spacing.l,
            bottom: Spacing.l,
            child: SafeArea(
              top: false,
              child: Material(
                color: Theme.of(context).colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(AppRadius.control),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.l, vertical: Spacing.m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Sale recorded · undo within ${_secondsLeft}s',
                          style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface),
                        ),
                      ),
                      TextButton(
                        onPressed: _undoing ? null : _undo,
                        child: _undoing
                            ? const ButtonSpinner()
                            : Text('UNDO', style: TextStyle(color: Theme.of(context).colorScheme.inversePrimary)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
