import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/api/api_client.dart';
import '../../../app/theme/app_theme.dart';

/// Mic capture for the "Voice sale" flow: tap to start, tap to stop (an
/// utterance can run 30-60s so press-and-hold would be awkward), then
/// upload the recording for the backend to transcribe and parse.
///
/// This records raw audio and uploads it rather than transcribing
/// on-device: a phone's built-in speech recognizer (the previous approach,
/// via the speech_to_text package) is a general-purpose engine with no
/// real chance against this app's actual input shape — Hinglish speech
/// that code-switches mid-sentence, full of pharmacy brand/generic names no
/// generic recognizer has ever seen. The backend instead sends the
/// recording to Gemini directly, which handles both far better when primed
/// with the right prompt (see services/voice_extraction.py). The trade-off
/// is losing the instant on-device partial-transcript feedback — replaced
/// here with a simple recording timer, and the transcript now only appears
/// once the server responds.
///
/// Pops with a job id (an int) the moment the recording is submitted, or
/// null if the user backs out without sending anything — transcription and
/// parsing happen later, in a background worker, not before this screen
/// returns. The caller polls ApiClient.getVoiceOrderJob(jobId) for the
/// result: SalesScreen tracks a fresh sale's job in its own in-flight list
/// (so the owner can immediately record a second note without waiting —
/// see SalesScreen's _voiceJobs), while VoiceOrderReviewScreen's "Add more"
/// flow (passing [appendToOrderId]) polls locally instead, since that's
/// scoped to the one order already on screen.
class VoiceSaleScreen extends StatefulWidget {
  final int? appendToOrderId;
  const VoiceSaleScreen({super.key, this.appendToOrderId});

  @override
  State<VoiceSaleScreen> createState() => _VoiceSaleScreenState();
}

class _VoiceSaleScreenState extends State<VoiceSaleScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _elapsedTimer;

  bool _initializing = true;
  bool _hasPermission = false;
  // _recording covers the whole session from start() to stop() — including
  // while paused — so dispose()'s "was a session left open" check and the
  // idle/ready-to-send UI branches don't need to know about _paused too.
  bool _recording = false;
  bool _paused = false;
  bool _uploading = false;
  Duration _elapsed = Duration.zero;
  String? _recordedPath;
  String? _errorMessage;

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

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  // Tapping the mic while idle, or while a finished recording is sitting
  // ready to send, both start a brand new session — the latter discards the
  // old recording, same "tap to re-record" behavior as before pause/resume
  // existed. Mid-session, the mic instead pauses/resumes (see build()).
  Future<void> _startRecording() async {
    if (!_hasPermission) {
      await _bootstrap();
      if (!_hasPermission) return;
    }

    setState(() {
      _recordedPath = null;
      _errorMessage = null;
      _elapsed = Duration.zero;
      _paused = false;
    });

    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_sale_${DateTime.now().millisecondsSinceEpoch}.wav';
      // WAV (PCM) rather than a compressed format: verified directly
      // against Gemini's audio input that this container/codec is reliably
      // accepted, and a 30-60s mono 16kHz recording is only ~1-2MB — small
      // enough that upload size isn't worth trading away that reliability.
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
        path: path,
      );
      _startElapsedTimer();
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not start recording: $e');
    }
  }

  // The `record` package pauses/resumes within the SAME underlying file —
  // stop() at the end still returns one continuous recording with the
  // paused stretch simply absent, so there's no clip-stitching to do here.
  Future<void> _pauseRecording() async {
    try {
      await _recorder.pause();
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not pause: $e');
      return;
    }
    _elapsedTimer?.cancel();
    if (mounted) setState(() => _paused = true);
  }

  Future<void> _resumeRecording() async {
    try {
      await _recorder.resume();
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not resume: $e');
      return;
    }
    _startElapsedTimer();
    if (mounted) setState(() => _paused = false);
  }

  Future<void> _finishRecording() async {
    _elapsedTimer?.cancel();
    try {
      final path = await _recorder.stop();
      if (mounted) {
        setState(() {
          _recording = false;
          _paused = false;
          _recordedPath = path;
          if (path == null) _errorMessage = "Didn't catch anything — tap the mic and try again.";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _paused = false;
          _errorMessage = 'Could not stop recording: $e';
        });
      }
    }
  }

  Future<void> _send() async {
    final path = _recordedPath;
    if (path == null || _uploading) return;
    setState(() {
      _uploading = true;
      _errorMessage = null;
    });
    try {
      final jobId = await ApiClient.instance.submitVoiceOrderAudio(
        File(path),
        voiceOrderId: widget.appendToOrderId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(jobId);
    } on ApiException catch (e) {
      // Transcription/parsing failures (structural_parse_failed, no-speech,
      // a Gemini-side error) can no longer happen here — they're worker-side
      // outcomes now, surfaced later via ApiClient.getVoiceOrderJob. What
      // can still fail at submit time is the synchronous part: the upload
      // itself, or (for "add more") the append target no longer existing.
      String msg;
      if (e.statusCode == 404) {
        msg = 'This order is no longer available to add more to.';
      } else if (e.statusCode == 409) {
        msg = (e.message.isNotEmpty ? e.message : "This order can't be added to anymore.");
      } else if (e.statusCode == 502) {
        msg = 'Could not store the recording right now: ${e.message}';
      } else {
        msg = 'Could not send: ${e.message}';
      }
      setState(() => _errorMessage = msg);
    } catch (e) {
      // Most likely no connectivity — keep the recording so the shopkeeper
      // can retry once back online instead of re-recording.
      setState(() => _errorMessage =
          'Could not reach the server — check your connection and tap Retry. '
          'Your recording is still here.');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final hasRecording = _recordedPath != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Voice sale')),
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
                            _recording
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _MicButton(
                                        recording: !_paused,
                                        paused: _paused,
                                        enabled: !_uploading,
                                        onTap: _paused ? _resumeRecording : _pauseRecording,
                                      ),
                                      const SizedBox(height: Spacing.m),
                                      TextButton.icon(
                                        onPressed: _uploading ? null : _finishRecording,
                                        icon: const Icon(Icons.stop_circle_outlined),
                                        label: const Text('Stop & review'),
                                      ),
                                    ],
                                  )
                                : _MicButton(
                                    recording: false,
                                    paused: false,
                                    enabled: _hasPermission && !_uploading,
                                    onTap: _startRecording,
                                  ),
                            const SizedBox(height: Spacing.l),
                            Text(
                              _recording
                                  ? (_paused
                                      ? 'Paused at ${_formatElapsed(_elapsed)} — tap the mic to continue speaking'
                                      : 'Recording ${_formatElapsed(_elapsed)} — tap to pause')
                                  : (hasRecording
                                      ? 'Recording ready — tap the mic to discard and re-record'
                                      : 'Tap the mic to speak a sale'),
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
                              child: Row(
                                children: [
                                  Icon(
                                    hasRecording ? Icons.graphic_eq : Icons.info_outline,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                  const SizedBox(width: Spacing.s),
                                  Expanded(
                                    child: Text(
                                      hasRecording
                                          ? 'Recorded ${_formatElapsed(_elapsed)} of audio, ready to send.'
                                          : 'e.g. "pan forty ka do strip, augmentin 625 ka ek strip" — say the whole sale, then stop.',
                                      style: TextStyle(
                                        color: hasRecording
                                            ? Theme.of(context).colorScheme.onSurface
                                            : Theme.of(context).colorScheme.outline,
                                        fontStyle: hasRecording ? FontStyle.normal : FontStyle.italic,
                                      ),
                                    ),
                                  ),
                                ],
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
              if (hasRecording && !_recording)
                FilledButton.icon(
                  onPressed: _uploading ? null : _send,
                  icon: _uploading
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send),
                  label: Text(_errorMessage != null ? 'Retry' : 'Send'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  // recording: actively capturing audio right now (tapping pauses it).
  // paused: session is open but not capturing (tapping resumes it).
  // Neither set: idle / ready-to-send (tapping starts a fresh recording).
  final bool recording;
  final bool paused;
  final bool enabled;
  final VoidCallback onTap;
  const _MicButton({required this.recording, required this.paused, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = recording
        ? AppColors.statusFailed
        : (paused ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.primary);
    final icon = recording ? Icons.pause : Icons.mic;
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
        child: Icon(icon, color: Colors.white, size: 40),
      ),
    );
  }
}
