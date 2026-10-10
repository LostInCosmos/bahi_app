import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/api/api_exception.dart';
import 'package:gst_bill_app/core/utils/poll.dart';

// DAS-21. The server now holds a status request open until something
// changes, which turns two things that were merely untidy into bugs:
//
//   - a deadline measured from submission calls a QUEUED job timed out, and
//     the retry that follows spends a fresh LLM call reproducing a result
//     already on its way (this is the bug DAS-19 fixed for bills);
//   - a dropped request is now routine, not exceptional, because the socket
//     is open for ~25s. It must mean "ask again", never "the job failed".
//
// These drive the loop with a scripted sequence of answers rather than a
// real clock, so they assert the decision, not the timing.

class _Job {
  _Job(this.status);
  final String status;
  bool get isTerminal => status == 'done' || status == 'failed';
  bool get isBeingWorkedOn => status == 'transcribing' || status == 'parsing';
}

/// Hands out [script] in order; `null` entries throw, standing in for a
/// dropped connection. Records how many times it was called.
class _Server {
  _Server(this.script);
  final List<String?> script;
  int calls = 0;

  Future<_Job> fetch() async {
    final i = calls++;
    final answer = i < script.length ? script[i] : script.last;
    if (answer == null) throw const SocketLikeFailure();
    return _Job(answer);
  }
}

class SocketLikeFailure implements Exception {
  const SocketLikeFailure();
}

Future<_Job> _run(_Server server, {Duration timeout = const Duration(milliseconds: 80)}) =>
    pollUntilTerminal<_Job>(
      fetch: server.fetch,
      isTerminal: (j) => j.isTerminal,
      isStarted: (j) => j.isBeingWorkedOn,
      timeout: timeout,
      transientBackoff: Duration.zero,
    );

void main() {
  group('the clock measures an attempt, not the wait for one', () {
    test('a long queue wait never times out', () async {
      // Thirty answers of "queued" — far more than the timeout's worth of
      // loop iterations. Before this, each one counted against the deadline.
      final server = _Server([...List.filled(30, 'queued'), 'transcribing', 'done']);
      final job = await _run(server);
      expect(job.status, 'done');
    });

    test('an attempt that really does hang times out', () async {
      final server = _Server(['transcribing']);
      await expectLater(
        _run(server, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('dropping back to queued starts the next attempt a fresh clock', () async {
      // A retry is a new attempt. Carrying the previous attempt's elapsed
      // time over would time the retry out almost immediately.
      final server = _Server([
        'transcribing', 'transcribing', 'transcribing',
        'queued', // reconciler re-queued it
        'transcribing', 'transcribing', 'transcribing',
        'done',
      ]);
      final job = await _run(server, timeout: const Duration(milliseconds: 40));
      expect(job.status, 'done');
    });

    test('with no isStarted the clock runs from the first answer', () async {
      // The old whole-job behaviour, kept for endpoints that answer at once.
      await expectLater(
        pollUntilTerminal<_Job>(
          fetch: _Server(['queued']).fetch,
          isTerminal: (j) => j.isTerminal,
          timeout: const Duration(milliseconds: 20),
          transientBackoff: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('a dropped request means ask again', () {
    test('a held request that drops is retried, not reported as failure', () async {
      final server = _Server([null, null, 'transcribing', 'done']);
      final job = await _run(server);
      expect(job.status, 'done');
      expect(server.calls, 4, reason: 'both drops were retried');
    });

    test('a server that is genuinely gone still surfaces the error', () async {
      final server = _Server([null]);
      await expectLater(
        _run(server, timeout: const Duration(seconds: 5)),
        throwsA(isA<SocketLikeFailure>()),
      );
      expect(server.calls, 4, reason: 'the first try plus transientFailures');
    });

    test('the failure budget resets after a good answer', () async {
      // Otherwise a long batch would exhaust three lifetime failures and
      // then die on the first blip an hour later.
      final server = _Server([null, null, null, 'transcribing', null, null, null, 'done']);
      final job = await _run(server);
      expect(job.status, 'done');
    });

    test('transientFailures: 0 restores fail-fast', () async {
      final server = _Server([null]);
      await expectLater(
        pollUntilTerminal<_Job>(
          fetch: server.fetch,
          isTerminal: (j) => j.isTerminal,
          timeout: const Duration(seconds: 5),
          transientFailures: 0,
        ),
        throwsA(isA<SocketLikeFailure>()),
      );
      expect(server.calls, 1);
    });
  });

  group('the held request costs no client-side interval', () {
    test('by default it asks again immediately', () async {
      // With ?wait=true the server already parked for up to 25s; sleeping on
      // top of that is pure added latency.
      final server = _Server(['queued', 'transcribing', 'done']);
      final sw = Stopwatch()..start();
      await _run(server, timeout: const Duration(seconds: 5));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100));
      expect(server.calls, 3);
    });

    test('an explicit interval is still honoured', () async {
      final server = _Server(['queued', 'done']);
      final sw = Stopwatch()..start();
      await pollUntilTerminal<_Job>(
        fetch: server.fetch,
        isTerminal: (j) => j.isTerminal,
        isStarted: (j) => j.isBeingWorkedOn,
        interval: const Duration(milliseconds: 60),
        timeout: const Duration(seconds: 5),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(60));
    });
  });

  group('with no time limit, the server decides', () {
    // Voice failed a note after 180s of one attempt and dropped it, though the
    // server went on to finish it — the bill flow's old mistake again.
    test('no timeout means no deadline, however long it is worked on', () async {
      final server = _Server([...List.filled(50, 'parsing'), 'done']);
      final job = await pollUntilTerminal<_Job>(
        fetch: server.fetch,
        isTerminal: (j) => j.isTerminal,
        transientBackoff: Duration.zero,
      );
      expect(job.status, 'done');
    });

    test('transientFailures: null keeps asking through any number of drops', () async {
      final server = _Server([...List<String?>.filled(20, null), 'done']);
      final job = await pollUntilTerminal<_Job>(
        fetch: server.fetch,
        isTerminal: (j) => j.isTerminal,
        transientFailures: null,
        transientBackoff: Duration.zero,
      );
      expect(job.status, 'done');
      expect(server.calls, 21);
    });

    test('it stops once its screen no longer wants the answer', () async {
      final server = _Server(['parsing']);
      var wanted = true;
      final waiting = pollUntilTerminal<_Job>(
        fetch: () async {
          if (server.calls == 3) wanted = false;
          return server.fetch();
        },
        isTerminal: (j) => j.isTerminal,
        transientFailures: null,
        stillWanted: () => wanted,
      );
      await expectLater(waiting, throwsA(isA<PollAbandoned>()));
      expect(server.calls, 4, reason: 'no request after the screen has gone');
    });
  });

  group('a refusal is not a dropped connection', () {
    test('a 4xx is rethrown at once, not retried', () async {
      var calls = 0;
      final waiting = pollUntilTerminal<_Job>(
        fetch: () async {
          calls++;
          throw ApiException(404, 'job not found');
        },
        isTerminal: (j) => j.isTerminal,
        transientFailures: null,
        transientBackoff: Duration.zero,
      );
      await expectLater(waiting, throwsA(isA<ApiException>()));
      expect(calls, 1);
    });

    test('a 429 or a 5xx is still worth asking again', () async {
      final answers = <Object>[ApiException(429, 'slow down'), ApiException(502, 'bad gateway'), _Job('done')];
      var i = 0;
      final job = await pollUntilTerminal<_Job>(
        fetch: () async {
          final a = answers[i++];
          if (a is Exception) throw a;
          return a as _Job;
        },
        isTerminal: (j) => j.isTerminal,
        transientBackoff: Duration.zero,
      );
      expect(job.status, 'done');
    });
  });
}
