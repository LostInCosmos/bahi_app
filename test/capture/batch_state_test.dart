import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/utils/offset_2d.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';

import 'realistic_batch.dart';

// DAS-92: the status loop writes the batch only when something it stores has
// changed. That rests on persistedState changing exactly when toJson's
// output does — so each case below checks both, and they must agree.

void main() {
  /// Applies [change] to a fresh bill; reports whether the stored state and
  /// the JSON each changed.
  ({bool state, bool json}) moved(void Function(BatchItem) change) {
    final bill = realisticBill(1);
    final stateBefore = bill.persistedState;
    final jsonBefore = jsonEncode(bill.toJson());
    change(bill);
    return (state: bill.persistedState != stateBefore, json: jsonEncode(bill.toJson()) != jsonBefore);
  }

  group('a change to anything stored is a change', () {
    final cases = <String, void Function(BatchItem)>{
      'status': (b) => b.status = BatchItemStatus.saved,
      'jobId': (b) => b.jobId = 99,
      'lastJobId': (b) => b.lastJobId = 99,
      'the read, replaced': (b) => b.result = realisticRead(2),
      'errorMessage': (b) => b.errorMessage = 'Qwen timed out',
      'savedInvoiceId': (b) => b.savedInvoiceId = 55,
      'folderId': (b) => b.folderId = 4,
      'sourceImages': (b) => b.sourceImages = ['8/1.jpg', '8/1b.jpg'],
      'a page added': (b) => b.pages = [
            ...b.pages,
            BatchItemPage(
                photoId: '8_1b',
                memoryBytes: null,
                filename: 'b.jpg',
                corners: const [Offset2D(0, 0), Offset2D(1, 0), Offset2D(1, 1), Offset2D(0, 1)],
                rotationDegrees: 0),
          ],
      'markFailed': (b) => b.markFailed('Could not read this bill'),
    };
    cases.forEach((name, change) {
      test(name, () {
        final m = moved(change);
        expect(m.json, isTrue, reason: 'the stored JSON changes');
        expect(m.state, isTrue, reason: 'so the state must too, or the write is skipped');
      });
    });
  });

  group('a change to something never stored is not', () {
    final cases = <String, void Function(BatchItem)>{
      'processingSince': (b) => b.processingSince = DateTime.utc(2026, 10, 18),
      'retryAt': (b) => b.retryAt = DateTime.utc(2026, 10, 18),
      'retryAttempt': (b) => b.retryAttempt = 2,
      'retryMax': (b) => b.retryMax = 5,
      'recheckedThisReview': (b) => b.recheckedThisReview = true,
      'failedAtSave': (b) => b.failedAtSave = true,
    };
    cases.forEach((name, change) {
      test(name, () {
        final m = moved(change);
        expect(m.json, isFalse, reason: 'not part of the stored JSON');
        expect(m.state, isFalse, reason: 'so a round that only moves this writes nothing');
      });
    });
  });

  test('batchState compares a batch by value, in order', () {
    final batch = [for (var i = 0; i < 300; i++) realisticBill(i)];
    final written = batchState(batch);
    expect(listEquals(batchState(batch), written), isTrue, reason: 'an idle round');

    batch[150].status = BatchItemStatus.saved;
    expect(listEquals(batchState(batch), written), isFalse, reason: 'one bill moved');
  });
}
