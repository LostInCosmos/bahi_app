import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';

const _prefsLocaleKey = 'voice_sale_locale';

/// Mic capture for the "Voice sale" flow: tap to start, tap to stop (an
/// utterance can run 30-60s so press-and-hold would be awkward), then send
/// the transcript to the backend to be parsed into a priced draft.
///
/// Pops with the parsed [VoiceOrder] on success, or null if the user backs
/// out without sending anything. When [appendToOrderId] is set (the "Add
/// more" flow from the review screen re-opening the mic) the newly parsed
/// lines are appended to that existing draft instead of starting a new one.
class VoiceSaleScreen extends StatefulWidget {
  final int? appendToOrderId;
  const VoiceSaleScreen({super.key, this.appendToOrderId});

  @override
  State<VoiceSaleScreen> createState() => _VoiceSaleScreenState();
}

class _VoiceSaleScreenState extends State<VoiceSaleScreen> {
  final SpeechToText _speech = SpeechToText();

  bool _speechAvailable = false;
  bool _initializing = true;
  bool _listening = false;
  bool _parsing = false;
  String _transcript = '';
  String _localeId = 'hi-IN';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    if (_listening) _speech.stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _localeId = prefs.getString(_prefsLocaleKey) ?? 'hi-IN');
    await _initSpeech();
  }

  Future<void> _initSpeech() async {
    setState(() {
      _initializing = true;
      _errorMessage = null;
    });
    bool available = false;
    try {
      available = await _speech.initialize(onStatus: _onStatus, onError: _onError);
    } catch (_) {
      available = false;
    }
    if (!mounted) return;
    setState(() {
      _speechAvailable = available;
      _initializing = false;
      if (!available) {
        _errorMessage = 'Microphone or speech recognition permission was not granted. '
            'Please enable "Microphone" (and "Speech recognition" on iOS) for this app '
            'in your device Settings, then try again.';
      }
    });
  }

  void _onStatus(String status) {
    // "listening" while active, "notListening"/"done" once the platform
    // stops on its own (long silence, or the OS/engine reached its own
    // limit) — treat both the same as our manual stop.
    if (status == 'notListening' || status == 'done') {
      if (mounted && _listening) setState(() => _listening = false);
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      if (error.errorMsg.contains('permission')) {
        _errorMessage = 'Microphone permission was denied. Enable it for this app in '
            'your device Settings to use voice sale.';
      } else if (error.errorMsg == 'error_no_match' || error.errorMsg == 'error_speech_timeout') {
        _errorMessage = _transcript.isEmpty
            ? "Didn't catch any speech — tap the mic and try again."
            : null;
      } else {
        _errorMessage = 'Speech recognition error: ${error.errorMsg}';
      }
    });
  }

  Future<void> _setLocale(String localeId) async {
    setState(() => _localeId = localeId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLocaleKey, localeId);
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_speechAvailable) {
      await _initSpeech();
      if (!_speechAvailable) return;
    }
    setState(() {
      _transcript = '';
      _errorMessage = null;
    });
    try {
      await _speech.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 8),
        ),
      );
      if (mounted) setState(() => _listening = true);
    } on SpeechToTextNotInitializedException {
      await _initSpeech();
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not start listening: $e');
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    setState(() => _transcript = result.recognizedWords);
  }

  Future<void> _send() async {
    final transcript = _transcript.trim();
    if (transcript.isEmpty || _parsing) return;
    setState(() {
      _parsing = true;
      _errorMessage = null;
    });
    try {
      final order = await ApiClient.instance.parseVoiceOrder(
        transcript,
        voiceOrderId: widget.appendToOrderId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(order);
    } on ApiException catch (e) {
      final detail = e.detail;
      String msg;
      if (detail is Map && detail['error'] == 'structural_parse_failed') {
        msg = (detail['message'] as String?) ?? "Couldn't understand that as a sale — try rephrasing.";
      } else if (e.statusCode == 502) {
        msg = 'The parsing service is unavailable right now: ${e.message}';
      } else {
        msg = 'Could not parse: ${e.message}';
      }
      setState(() => _errorMessage = msg);
    } catch (e) {
      // Most likely no connectivity — keep the transcript so the shopkeeper
      // can retry once back online instead of re-recording.
      setState(() => _errorMessage =
          'Could not reach the server — check your connection and tap Retry. '
          'Your words are still here.');
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTranscript = _transcript.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice sale'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.s),
            child: Center(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'hi-IN', label: Text('हिन्दी')),
                  ButtonSegment(value: 'en-IN', label: Text('English')),
                ],
                selected: {_localeId},
                onSelectionChanged: _listening
                    ? null
                    : (s) => _setLocale(s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ),
          ),
        ],
      ),
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
                              listening: _listening,
                              enabled: _speechAvailable && !_parsing,
                              onTap: _toggleListen,
                            ),
                            const SizedBox(height: Spacing.l),
                            Text(
                              _listening
                                  ? 'Listening… tap to stop'
                                  : (hasTranscript ? 'Tap to record again' : 'Tap the mic to speak a sale'),
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
                              child: Text(
                                hasTranscript ? _transcript : 'e.g. "pan forty ka do strip, augmentin 625 ka ek strip"',
                                style: TextStyle(
                                  color: hasTranscript
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(context).colorScheme.outline,
                                  fontStyle: hasTranscript ? FontStyle.normal : FontStyle.italic,
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
              if (hasTranscript && !_listening)
                FilledButton.icon(
                  onPressed: _parsing ? null : _send,
                  icon: _parsing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send),
                  label: Text(_errorMessage != null ? 'Retry' : 'Parse sale'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  final bool listening;
  final bool enabled;
  final VoidCallback onTap;
  const _MicButton({required this.listening, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = listening ? AppColors.statusFailed : Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: enabled ? color : Theme.of(context).colorScheme.outlineVariant,
          shape: BoxShape.circle,
          boxShadow: listening
              ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 4)]
              : null,
        ),
        child: Icon(listening ? Icons.stop : Icons.mic, color: Colors.white, size: 40),
      ),
    );
  }
}
