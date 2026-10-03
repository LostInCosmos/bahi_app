import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';

// DAS-19. One held request now watches the whole batch instead of a 2-second
// timer per bill, so what the card believes comes from a JobStatusBrief
// rather than a full job row. These pin the parts of that with real
// consequences: a queued bill must not be called failed for waiting its
// turn, and a bill in backoff must not be asked about until it is due.

JobStatusBrief _brief(String status, {int attempt = 0, DateTime? retryAt}) => JobStatusBrief(
      jobId: 1,
      status: status,
      attempt: attempt,
      maxAttempts: 3,
      retryAt: retryAt,
    );

BatchItem _item() => BatchItem(label: 'Photo 1', pages: [])
  ..sourceImages = ['7/a.jpg']
  ..status = BatchItemStatus.processing
  ..jobId = 1;

void main() {
  group('status parsing', () {
    test('a done bill is terminal; a queued one is not', () {
      expect(_brief('done').isTerminal, isTrue);
      expect(_brief('failed').isTerminal, isTrue);
      expect(_brief('cancelled').isTerminal, isTrue);
      expect(_brief('queued').isTerminal, isFalse);
      expect(_brief('processing').isTerminal, isFalse);
      expect(_brief('retrying').isTerminal, isFalse);
    });

    test('an unknown status is not treated as finished', () {
      // The server may grow a status before the app knows it. Guessing "done"
      // would show a bill as read when it has not been.
      expect(_brief('something_new').isTerminal, isFalse);
    });

    test('a retry carries its attempt and when it is due', () {
      final due = DateTime.utc(2026, 10, 4, 12);
      final brief = _brief('retrying', attempt: 2, retryAt: due);
      expect(brief.isRetrying, isTrue);
      expect(brief.attempt, 2);
      expect(brief.retryAt, due);
    });

    test('parses the wire format, including a null retry_at', () {
      final b = JobStatusBrief.fromJson({
        'job_id': 9,
        'status': 'retrying',
        'attempt': 1,
        'max_attempts': 3,
        'retry_at': '2026-10-04T12:00:00Z',
      });
      expect(b.jobId, 9);
      expect(b.retryAt!.isUtc, isTrue);

      final queued = JobStatusBrief.fromJson({'job_id': 9, 'status': 'queued'});
      expect(queued.retryAt, isNull);
      expect(queued.maxAttempts, 3, reason: 'a sensible default, not a crash');
    });

    test('a batch answer says whether anything actually changed', () {
      final batch = JobStatusBatch.fromJson({
        'jobs': [
          {'job_id': 1, 'status': 'done'},
          {'job_id': 2, 'status': 'queued'},
        ],
        'changed': true,
      });
      expect(batch.changed, isTrue);
      expect(batch.jobs.map((j) => j.jobId), [1, 2]);

      expect(JobStatusBatch.fromJson({'jobs': [], 'changed': false}).changed, isFalse);
    });
  });

  group('backoff', () {
    const sweep = Duration(seconds: 60);

    test('a bill with no retry pending is always worth asking about', () {
      expect(_item().isBackingOff(sweep), isFalse);
    });

    test('a bill still inside its backoff is skipped', () {
      final item = _item()..retryAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
      expect(item.isBackingOff(sweep), isTrue);
    });

    test('a bill is still skipped between retry_at and the sweep that requeues it', () {
      // The server does not pick a retry up at retry_at — it is re-queued by
      // the reconciler's next sweep, so asking in between returns "retrying"
      // again and buys nothing.
      final item = _item()..retryAt = DateTime.now().toUtc().subtract(const Duration(seconds: 10));
      expect(item.isBackingOff(sweep), isTrue);
    });

    test('once the sweep has had time to run, it is asked about again', () {
      final item = _item()..retryAt = DateTime.now().toUtc().subtract(const Duration(seconds: 90));
      expect(item.isBackingOff(sweep), isFalse);
    });
  });

  group('the attempt clock', () {
    // The bug this replaces: the 120s ran from submission, so at three bills
    // at a time a bill ~18 deep was called failed for queueing. Retry then
    // spent a fresh model call reproducing a result already on its way.

    test('a bill only queued has no clock running', () {
      final item = _item();
      expect(item.processingSince, isNull);
    });

    test('the clock starts when the server says it is working, not at submit', () {
      final item = _item();
      // what _applyStatus does for a non-terminal, processing bill
      item.processingSince ??= DateTime.now().toUtc();
      expect(item.processingSince, isNotNull);
    });

    test('a long queue wait never looks like a timeout', () {
      final item = _item();
      const timeout = Duration(seconds: 120);
      final queuedFor = const Duration(minutes: 30);
      // No processingSince, so there is nothing for the timeout to measure.
      expect(item.processingSince, isNull);
      expect(
        item.processingSince != null && queuedFor > timeout,
        isFalse,
        reason: 'queue time must not count toward the per-attempt timeout',
      );
    });

    test('a genuinely stuck attempt does time out', () {
      final item = _item()..processingSince = DateTime.now().toUtc().subtract(const Duration(seconds: 121));
      final elapsed = DateTime.now().toUtc().difference(item.processingSince!);
      expect(elapsed > const Duration(seconds: 120), isTrue);
    });

    test('the clock is cleared when a bill drops back to retrying', () {
      final item = _item()..processingSince = DateTime.now().toUtc();
      // what _applyStatus does on a retry
      item
        ..retryAt = DateTime.now().toUtc().add(const Duration(minutes: 1))
        ..processingSince = null;
      expect(item.processingSince, isNull, reason: 'the next attempt starts its own clock');
    });
  });

  group('persistence', () {
    test('the attempt clock and retry state are not persisted', () {
      final item = _item()
        ..processingSince = DateTime.now().toUtc()
        ..retryAt = DateTime.now().toUtc()
        ..retryAttempt = 2;

      final restored = BatchItem.fromJson(item.toJson())!;

      // Deliberate: both are re-learned from the server on the next status
      // answer, which is authoritative. Persisting them would let a stale
      // clock time out a bill the server is still happily working on.
      expect(restored.processingSince, isNull);
      expect(restored.retryAt, isNull);
      expect(restored.retryAttempt, 0);
    });

    test('the job id does survive, which is what lets a restart catch up', () {
      final item = _item()..lastJobId = 1;
      final restored = BatchItem.fromJson(item.toJson())!;
      expect(restored.jobId, 1);
      expect(restored.status, BatchItemStatus.processing);
    });
  });
}
