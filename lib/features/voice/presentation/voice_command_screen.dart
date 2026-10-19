import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/inline_message.dart';
import '../data/voice_api.dart';
import '../models/voice.dart';
import '../widgets/recording.dart';

/// General voice commands — "how much Maggi do I have", "delete Sharma's
/// sale from yesterday", "add 20 Maggi to inventory" — distinct from the
/// "Voice sale" screen, which only ever handles speaking a full multi-item
/// sale. Same record-then-upload approach as voice_sale_screen.dart (the
/// backend transcribes with Gemini, not on-device) since the same
/// Hinglish/no-domain-vocabulary problem applies here too.
///
/// A destructive result (requiresConfirmation) always shows a confirm/
/// cancel dialog before the confirmation token is ever sent back — the
/// backend re-validates everything again at that point too, but the app
/// never sends `confirmed: true` on its own say-so either way.
class VoiceCommandScreen extends StatefulWidget {
  const VoiceCommandScreen({super.key});

  @override
  State<VoiceCommandScreen> createState() => _VoiceCommandScreenState();
}

class _VoiceCommandScreenState extends State<VoiceCommandScreen> with RecordingSupport {
  bool _recording = false;
  bool _processing = false;
  String? _errorMessage;
  VoiceCommandResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    disposeRecording(sessionOpen: _recording);
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (!await checkMic() && mounted) setState(() => _errorMessage = kMicPermissionMessage);
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopAndSend();
      return;
    }
    if (!hasPermission) {
      await _bootstrap();
      if (!hasPermission) return;
    }

    setState(() {
      _errorMessage = null;
      _lastResult = null;
    });

    try {
      await startRecordingFile('voice_command');
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = recordingErrorMessage(e));
    }
  }

  Future<void> _stopAndSend() async {
    String? path;
    try {
      path = await stopRecordingFile();
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _errorMessage = 'Could not stop recording: $e';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _recording = false);
    if (path == null) {
      setState(() => _errorMessage = "Didn't catch anything — tap the mic and try again.");
      return;
    }
    await _send(path);
  }

  Future<void> _send(String path) async {
    setState(() {
      _processing = true;
      _errorMessage = null;
    });
    try {
      final result = await ApiClient.instance.sendVoiceCommand(File(path));
      if (!mounted) return;
      setState(() => _lastResult = result);
      if (result.requiresConfirmation && result.confirmationToken != null) {
        await _showConfirmDialog(result);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.statusCode == 429
            ? "You're sending commands too quickly — please wait a moment and try again."
            : 'Could not process that: ${e.message}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not reach the server — check your connection and tap the mic to retry.');
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _showConfirmDialog(VoiceCommandResult result) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Confirm',
      message: result.message,
      confirmLabel: 'Confirm',
      barrierDismissible: false,
    );
    if (!confirmed || !mounted) return;

    setState(() => _processing = true);
    try {
      final executed = await ApiClient.instance.confirmVoiceCommand(result.confirmationToken!);
      if (mounted) setState(() => _lastResult = executed);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.statusCode == 409
            ? 'That was already handled.'
            : e.statusCode == 410
                ? 'That confirmation expired — please repeat the command.'
                : 'Could not complete that: ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not reach the server to confirm — please try again.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final result = _lastResult;
    return Scaffold(
      appBar: AppBar(title: const Text('Voice command')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.l),
          child: Center(
            child: micChecking
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      MicButton(
                        recordingIcon: Icons.stop,
                        recording: _recording,
                        enabled: hasPermission && !_processing,
                        onTap: _toggleRecording,
                      ),
                      const SizedBox(height: Spacing.l),
                      Text(
                        _recording
                            ? 'Listening ${formatElapsed(elapsed)} — tap to stop'
                            : (_processing ? 'Working on it…' : 'Tap the mic and speak a command'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: Spacing.l),
                      VoiceHintBox(
                        child: _processing
                            ? const Center(child: CircularProgressIndicator())
                            : Text(
                                result?.message ??
                                    'e.g. "how much Maggi do I have", "delete Sharma\'s sale from yesterday", '
                                        '"add 20 Maggi to inventory"',
                                style: TextStyle(
                                  color: result == null
                                      ? colors.outline
                                      : (result.success ? colors.onSurface : AppColors.statusFailed),
                                  fontStyle: result == null ? FontStyle.italic : FontStyle.normal,
                                ),
                              ),
                      ),
                      ErrorText(_errorMessage, textAlign: TextAlign.center),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
