import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/api/api_client.dart';
import '../models/voice.dart';
import '../../../app/theme/app_theme.dart';

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

class _VoiceCommandScreenState extends State<VoiceCommandScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _elapsedTimer;

  bool _initializing = true;
  bool _hasPermission = false;
  bool _recording = false;
  bool _processing = false;
  Duration _elapsed = Duration.zero;
  String? _errorMessage;
  VoiceCommandResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    if (_recording) _recorder.stop();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _initializing = true);
    bool granted = false;
    try {
      granted = await _recorder.hasPermission();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    setState(() {
      _hasPermission = granted;
      _initializing = false;
      if (!granted) {
        _errorMessage = 'Microphone permission was not granted. Please enable "Microphone" '
            'for this app in your device Settings, then try again.';
      }
    });
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopAndSend();
      return;
    }
    if (!_hasPermission) {
      await _bootstrap();
      if (!_hasPermission) return;
    }

    setState(() {
      _errorMessage = null;
      _lastResult = null;
      _elapsed = Duration.zero;
    });

    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_command_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
        path: path,
      );
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not start recording: $e');
    }
  }

  Future<void> _stopAndSend() async {
    _elapsedTimer?.cancel();
    String? path;
    try {
      path = await _recorder.stop();
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
      setState(() => _errorMessage = e.statusCode == 429
          ? "You're sending commands too quickly — please wait a moment and try again."
          : 'Could not process that: ${e.message}');
    } catch (e) {
      setState(() => _errorMessage =
          'Could not reach the server — check your connection and tap the mic to retry.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _showConfirmDialog(VoiceCommandResult result) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm'),
        content: Text(result.message),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

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

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice command')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.l),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: _initializing
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _MicButton(
                              recording: _recording,
                              enabled: _hasPermission && !_processing,
                              onTap: _toggleRecording,
                            ),
                            const SizedBox(height: Spacing.l),
                            Text(
                              _recording
                                  ? 'Listening ${_formatElapsed(_elapsed)} — tap to stop'
                                  : (_processing ? 'Working on it…' : 'Tap the mic and speak a command'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: Spacing.l),
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(minHeight: 96),
                              padding: const EdgeInsets.all(Spacing.m),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(AppRadius.control),
                              ),
                              child: _processing
                                  ? const Center(child: CircularProgressIndicator())
                                  : Text(
                                      _lastResult?.message ??
                                          'e.g. "how much Maggi do I have", "delete Sharma\'s sale from yesterday", '
                                              '"add 20 Maggi to inventory"',
                                      style: TextStyle(
                                        color: _lastResult != null
                                            ? (_lastResult!.success
                                                ? Theme.of(context).colorScheme.onSurface
                                                : AppColors.statusFailed)
                                            : Theme.of(context).colorScheme.outline,
                                        fontStyle: _lastResult != null ? FontStyle.normal : FontStyle.italic,
                                      ),
                                    ),
                            ),
                            if (_errorMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(top: Spacing.m),
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  final bool recording;
  final bool enabled;
  final VoidCallback onTap;
  const _MicButton({required this.recording, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = recording ? AppColors.statusFailed : Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: enabled ? color : Theme.of(context).colorScheme.outlineVariant,
          shape: BoxShape.circle,
          boxShadow: recording
              ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 4)]
              : null,
        ),
        child: Icon(recording ? Icons.stop : Icons.mic, color: Colors.white, size: 40),
      ),
    );
  }
}
