import 'dart:async';

/// Repeatedly calls [fetch] (typically a "get job status" endpoint) until
/// [isTerminal] says the result is done, and returns that result. Throws a
/// [TimeoutException] if [timeout] elapses first, so callers keep their own
/// terminal-branch handling (done/failed/timeout can mean different things
/// per screen) but not the loop mechanics.
///
/// Three things here exist because the server now holds the request open
/// instead of answering instantly (DAS-19 for bills, DAS-21 for voice):
///
/// 1. **[interval] defaults to zero.** With `?wait=true` the server parks the
///    request until something changes, up to ~25s, so a client-side delay on
///    top only adds latency. Pass a real interval for an endpoint that still
///    answers immediately.
/// 2. **[isStarted] decides when the clock starts.** A job can sit queued
///    behind other work for far longer than it takes to run, so a deadline
///    measured from submission calls a *queued* job timed out — and the
///    retry that follows spends a fresh LLM call reproducing a result
///    already on its way. That was a real bug on bills. The deadline below
///    measures the attempt, not the wait for one, and restarts if the job
///    drops back to queued (a retry is a new attempt).
/// 3. **[transientFailures] of [fetch] are tolerated.** Holding a socket open
///    for 25s means tunnels, network switches and NAT timeouts land on the
///    client routinely. A dropped request must mean "ask again", never "the
///    job failed" — the next call re-reads current state, so nothing is lost
///    by retrying. Set it to 0 to get the old fail-fast behaviour.
Future<T> pollUntilTerminal<T>({
  required Future<T> Function() fetch,
  required bool Function(T result) isTerminal,
  required Duration timeout,
  Duration interval = Duration.zero,
  bool Function(T result)? isStarted,
  int transientFailures = 3,
  Duration transientBackoff = const Duration(seconds: 2),
}) async {
  // Null until the job is known to be running. With no [isStarted] the clock
  // starts at the first answer, which is the old whole-job behaviour.
  DateTime? startedAt;
  var consecutiveFailures = 0;

  while (true) {
    final T result;
    try {
      result = await fetch();
    } catch (_) {
      consecutiveFailures++;
      if (consecutiveFailures > transientFailures) rethrow;
      await Future.delayed(transientBackoff);
      continue;
    }
    consecutiveFailures = 0;

    if (isTerminal(result)) return result;

    if (isStarted == null || isStarted(result)) {
      startedAt ??= DateTime.now();
      if (DateTime.now().difference(startedAt) > timeout) {
        throw TimeoutException('Job did not finish within $timeout of starting');
      }
    } else {
      // Back to queued or backing off: the next attempt gets its own clock.
      startedAt = null;
    }

    if (interval > Duration.zero) await Future.delayed(interval);
  }
}
