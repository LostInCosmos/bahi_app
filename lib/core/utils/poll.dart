import 'dart:async';

import '../api/api_exception.dart';

/// Thrown by [pollUntilTerminal] once its caller no longer wants the answer
/// (the screen watching the job has closed). Callers that already return on
/// `!mounted` after a failure need no special handling for it.
class PollAbandoned implements Exception {
  const PollAbandoned();
}

/// Repeatedly calls [fetch] (typically a "get job status" endpoint) until
/// [isTerminal] says the result is done, and returns that result. Throws a
/// [TimeoutException] if a [timeout] is given and elapses first, so callers
/// keep their own terminal-branch handling (done/failed/timeout can mean
/// different things per screen) but not the loop mechanics.
///
/// With no [timeout] the server alone decides when a job is over — it fails a
/// job nobody is working on — which is what bills and voice both do now: a
/// phone that gave up first called jobs failed that the server went on to
/// finish. Such a wait should pass [stillWanted], so it ends when its screen
/// does (by throwing [PollAbandoned]) rather than outliving it.
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
///    by retrying. Set it to 0 to get the old fail-fast behaviour, or null to
///    keep asking for as long as [stillWanted] says so. A request the server
///    *answered* with a refusal (a 4xx: the job is gone, or the session has
///    ended) is not transient and is never retried.
Future<T> pollUntilTerminal<T>({
  required Future<T> Function() fetch,
  required bool Function(T result) isTerminal,
  Duration? timeout,
  Duration interval = Duration.zero,
  bool Function(T result)? isStarted,
  int? transientFailures = 3,
  Duration transientBackoff = const Duration(seconds: 2),
  bool Function()? stillWanted,
}) async {
  // Null until the job is known to be running. With no [isStarted] the clock
  // starts at the first answer, which is the old whole-job behaviour.
  DateTime? startedAt;
  var consecutiveFailures = 0;

  void checkWanted() {
    if (stillWanted != null && !stillWanted()) throw const PollAbandoned();
  }

  while (true) {
    checkWanted();
    final T result;
    try {
      result = await fetch();
    } catch (e) {
      if (_refused(e)) rethrow;
      consecutiveFailures++;
      final allowed = transientFailures;
      if (allowed != null && consecutiveFailures > allowed) rethrow;
      await Future.delayed(transientBackoff);
      continue;
    }
    consecutiveFailures = 0;

    if (isTerminal(result)) return result;

    if (isStarted == null || isStarted(result)) {
      startedAt ??= DateTime.now();
      if (timeout != null && DateTime.now().difference(startedAt) > timeout) {
        throw TimeoutException('Job did not finish within $timeout of starting');
      }
    } else {
      // Back to queued or backing off: the next attempt gets its own clock.
      startedAt = null;
    }

    if (interval > Duration.zero) await Future.delayed(interval);
  }
}

/// The server answered, and said no: asking again gets the same answer.
/// Request Timeout (408) and Too Many Requests (429) are worth another try.
bool _refused(Object error) =>
    error is ApiException &&
    error.statusCode >= 400 &&
    error.statusCode < 500 &&
    error.statusCode != 408 &&
    error.statusCode != 429;
