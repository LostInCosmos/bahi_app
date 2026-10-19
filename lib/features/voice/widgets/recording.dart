import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../app/theme/app_theme.dart';

export '../../../core/utils/format.dart' show formatElapsed;

/// What the voice sale and voice command screens share about recording. They
/// grew from one screen copied, and the copies had already drifted (one
/// pauses, one only stops); the parts that must not differ live here.

/// WAV (PCM) rather than a compressed format: verified directly against the
/// transcription model's audio input that this container/codec is reliably
/// accepted, and a 30-60s mono 16kHz recording is only ~1-2MB — small enough
/// that upload size isn't worth trading away that reliability. The backend
/// reads the type from the `.wav` extension.
const kVoiceRecordConfig = RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1);

/// A fresh file for one recording, named [prefix]_<time>.wav in temp storage.
Future<String> newRecordingPath(String prefix) async {
  final dir = await getTemporaryDirectory();
  return '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.wav';
}

const kMicPermissionMessage = 'Microphone permission was not granted. Please enable "Microphone" '
    'for this app in your device Settings, then try again.';

/// Whether the microphone may be used; asks if it has not been asked yet.
/// A plugin failure counts as no.
Future<bool> hasMicPermission(AudioRecorder recorder) async {
  try {
    return await recorder.hasPermission();
  } catch (_) {
    return false;
  }
}

/// Turns a recorder failure into something a shopkeeper can act on.
///
/// iOS surfaces `PlatformException(record, Failed to start recording,
/// setActive: Session activation failed)` when AVAudioSession can't be
/// claimed — almost always because something else already holds the
/// microphone (an ongoing call, another recording app, CarPlay). The raw
/// platform string means nothing to the user, so name the likely cause and
/// what to do about it.
String recordingErrorMessage(Object e) {
  final raw = e.toString();
  if (raw.contains('Session activation failed') || raw.contains('AVAudioSession')) {
    return 'Could not use the microphone — something else may be using it. '
        'End any ongoing call or close other recording apps, then try again.';
  }
  if (raw.contains('Permission') || raw.contains('permission')) {
    return 'Microphone permission is off. Turn it on in Settings, then try again.';
  }
  return 'Could not start recording: $raw';
}

/// The recorder, the permission check and the elapsed-time clock a recording
/// screen needs — the half of each voice screen that was the same in both.
/// The screen keeps its own flow (one pauses, one only stops) and its own
/// `setState`s; this owns the objects and tears them down.
///
/// Call [initRecording] from `initState` and [disposeRecording] from
/// `dispose`. The mixin never calls `setState` itself; every method says
/// what changed and the screen redraws.
mixin RecordingSupport<T extends StatefulWidget> on State<T> {
  final AudioRecorder recorder = AudioRecorder();
  Timer? _elapsedTimer;

  /// Still asking about the microphone.
  bool micChecking = true;
  bool hasPermission = false;

  /// How long the current session has recorded, paused stretches excluded.
  Duration elapsed = Duration.zero;

  /// Asks for the microphone (the first time: the system prompt). Sets
  /// [hasPermission] and clears [micChecking]; returns whether it may be used.
  Future<bool> checkMic() async {
    setState(() => micChecking = true);
    final granted = await hasMicPermission(recorder);
    if (!mounted) return false;
    setState(() {
      hasPermission = granted;
      micChecking = false;
    });
    return granted;
  }

  /// Starts (or restarts) the second-by-second clock; [elapsed] is not reset.
  void startElapsed() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => elapsed += const Duration(seconds: 1));
    });
  }

  void stopElapsed() => _elapsedTimer?.cancel();

  /// Begins a fresh recording into a new file named after [prefix], from zero.
  Future<void> startRecordingFile(String prefix) async {
    elapsed = Duration.zero;
    await recorder.start(kVoiceRecordConfig, path: await newRecordingPath(prefix));
    startElapsed();
  }

  /// Stops the recorder; the file's path, or null if nothing was captured.
  Future<String?> stopRecordingFile() {
    stopElapsed();
    return recorder.stop();
  }

  /// Call from `dispose`. [sessionOpen]: whether a recording is still running,
  /// so it is stopped before the recorder goes.
  void disposeRecording({required bool sessionOpen}) {
    _elapsedTimer?.cancel();
    if (sessionOpen) recorder.stop();
    recorder.dispose();
  }
}

/// The hint box under the mic button: an example phrase in italics until there
/// is something to show, then the result in the body colour.
class VoiceHintBox extends StatelessWidget {
  final Widget child;
  const VoiceHintBox({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 96),
        padding: const EdgeInsets.all(Spacing.m),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: child,
      );
}

/// The big round record button.
///
/// [recording]: capturing audio right now — red, glowing, showing
/// [recordingIcon] (pause where tapping pauses, stop where it stops).
/// [paused]: a session is open but not capturing — tapping resumes.
/// Neither: idle, or a recording waiting to be sent — tapping starts afresh.
class MicButton extends StatelessWidget {
  final bool recording;
  final bool paused;
  final bool enabled;
  final IconData recordingIcon;
  final VoidCallback onTap;

  const MicButton({
    super.key,
    required this.recording,
    this.paused = false,
    required this.enabled,
    required this.recordingIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = recording ? AppColors.statusFailed : (paused ? scheme.secondary : scheme.primary);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: enabled ? color : scheme.outlineVariant,
          shape: BoxShape.circle,
          boxShadow: recording ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 4)] : null,
        ),
        child: Icon(recording ? recordingIcon : Icons.mic, color: Colors.white, size: 40),
      ),
    );
  }
}
