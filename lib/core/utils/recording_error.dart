/// Turns a recorder failure into something a shopkeeper can act on.
///
/// iOS surfaces `PlatformException(record, Failed to start recording,
/// setActive: Session activation failed)` when AVAudioSession can't be
/// claimed — almost always because something else already holds the
/// microphone (an ongoing call, another recording app, CarPlay). The raw
/// platform string means nothing to the user, so name the likely cause and
/// what to do about it.
///
/// Shared by the voice sale and voice command screens, which both start a
/// recording the same way.
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
