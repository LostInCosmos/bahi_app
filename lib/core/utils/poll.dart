import 'dart:async';

/// Repeatedly calls [fetch] (typically a "get job status" endpoint) until
/// [isTerminal] says the result is done — waiting [interval] between tries —
/// and returns that result. Throws a [TimeoutException] if [timeout] elapses
/// first, so callers keep their own terminal-branch handling (done/failed/
/// timeout can mean different things per screen) but not the loop mechanics.
///
/// Used by every screen that submits a background job (bill extraction,
/// voice-order parsing) and polls for its result — one implementation
/// instead of three near-identical copies of the same submit-then-poll loop.
Future<T> pollUntilTerminal<T>({
  required Future<T> Function() fetch,
  required bool Function(T result) isTerminal,
  required Duration timeout,
  Duration interval = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final result = await fetch();
    if (isTerminal(result)) return result;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Polling timed out after $timeout');
    }
    await Future.delayed(interval);
  }
}
