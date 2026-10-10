import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../app/theme/app_theme.dart';

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

/// mm:ss.
String formatElapsed(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
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
