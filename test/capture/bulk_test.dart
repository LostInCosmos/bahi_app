import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/bulk.dart';
import 'package:gst_bill_app/features/capture/models/list_entry.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';

/// Mirrors shop_webapp/test/bulk.test.js: the two clients must agree on
/// what a shopkeeper can do to several bills at once.

ListEntry _local({
  BatchItemStatus status = BatchItemStatus.pendingConfirm,
  int? jobId,
  int? lastJobId,
  int? savedInvoiceId,
}) {
  final item = BatchItem(label: 'Bill', pages: [])
    ..status = status
    ..jobId = jobId
    ..lastJobId = lastJobId
    ..savedInvoiceId = savedInvoiceId;
  return ListEntry(id: 'l:x', sortKey: 0, card: const SizedBox(), item: item);
}

ListEntry _job({int id = 5, String status = 'done', int? invoiceId}) => ListEntry(
      id: 'j:$id',
      sortKey: id,
      card: const SizedBox(),
      upload: UploadSummary(
        jobId: id,
        status: status,
        sourceImage: '8/$id.jpg',
        createdAt: DateTime(2026, 10, 8),
        invoiceId: invoiceId,
      ),
    );

void main() {
  group('where a card sits in the list', () {
    test('is its upload order: a bill with a server id sorts by that id', () {
      expect(localSortKey((BatchItem(label: 'a', pages: [])..lastJobId = 42), 0), 42);
      expect(localSortKey((BatchItem(label: 'a', pages: [])..jobId = 43), 0), 43);
    });

    test('does not change when a bill is opened, retried or moved', () {
      final item = BatchItem(label: 'a', pages: [])..lastJobId = 42;
      final before = localSortKey(item, 3);
      item
        ..status = BatchItemStatus.saved
        ..folderId = 7;
      expect(localSortKey(item, 3), before);
    });

    test('puts a bill with no server id yet ahead of every uploaded one', () {
      final fresh = BatchItem(label: 'a', pages: []);
      final uploaded = BatchItem(label: 'b', pages: [])..lastJobId = 9999999;
      expect(localSortKey(fresh, 0), greaterThan(localSortKey(uploaded, 0)));
      expect(localSortKey(fresh, 0), greaterThanOrEqualTo(kNewest));
    });

    test('puts the photo added last first among those', () {
      final item = BatchItem(label: 'a', pages: []);
      expect(localSortKey(item, 5), greaterThan(localSortKey(item, 2)));
    });

    test('interleaves device and shop bills by id, not by where they live', () {
      final keys = <String, int>{
        'l:a': localSortKey((BatchItem(label: 'a', pages: [])..lastJobId = 10), 0),
        'j:30': 30,
        'l:b': localSortKey((BatchItem(label: 'b', pages: [])..lastJobId = 20), 1),
        'j:5': 5,
      };
      final order = keys.keys.toList()..sort((a, b) => keys[b]!.compareTo(keys[a]!));
      // A device-held bill sits BETWEEN shop bills, not above them all.
      expect(order, ['j:30', 'l:b', 'l:a', 'j:5']);
    });
  });

  group('what Discard may take', () {
    test('takes a read bill that was never saved', () {
      expect(whyNotDiscard(_local()), isNull);
      expect(whyNotDiscard(_job()), isNull);
    });

    test('refuses a saved bill — that is a stock decision, not tidying', () {
      expect(whyNotDiscard(_local(status: BatchItemStatus.saved, savedInvoiceId: 3)), DiscardRefusal.saved);
      expect(whyNotDiscard(_job(invoiceId: 3)), DiscardRefusal.saved);
    });

    test('refuses a bill the server is still reading', () {
      for (final status in ['pending', 'queued', 'processing', 'retrying']) {
        expect(whyNotDiscard(_job(status: status)), DiscardRefusal.reading, reason: status);
      }
      expect(whyNotDiscard(_local(status: BatchItemStatus.processing)), DiscardRefusal.reading);
    });

    test('takes a failed bill, which nothing is working on', () {
      expect(whyNotDiscard(_job(status: 'failed')), isNull);
      expect(whyNotDiscard(_local(status: BatchItemStatus.failed)), isNull);
    });

    test('splits a mixed selection and counts what was left', () {
      final plan = planDiscard([
        _local(),
        _job(),
        _job(id: 6, invoiceId: 9),
        _local(status: BatchItemStatus.saved, savedInvoiceId: 4),
        _job(id: 7, status: 'processing'),
      ]);
      expect(plan.take, hasLength(2));
      expect(plan.savedLeft, 2);
      expect(plan.readingLeft, 1);
    });
  });

  group('which call files a bill', () {
    test('a saved bill is filed through its invoice, wherever it is listed', () {
      final a = moveStep(_local(status: BatchItemStatus.saved, savedInvoiceId: 3));
      expect((a.via, a.id), (MoveVia.invoice, 3));
      final b = moveStep(_job(invoiceId: 8));
      expect((b.via, b.id), (MoveVia.invoice, 8));
    });

    test('a read, unsaved bill is filed through its upload', () {
      final a = moveStep(_job());
      expect((a.via, a.id), (MoveVia.job, 5));
      final b = moveStep(_local(lastJobId: 12));
      expect((b.via, b.id), (MoveVia.job, 12));
    });

    test('a bill the server has not seen yet can only be filed on this device', () {
      expect(moveStep(_local(status: BatchItemStatus.needsCrop)).via, MoveVia.local);
    });

    test("knows a bill's server id from either kind of card", () {
      expect(jobIdOf(_job()), 5);
      expect(jobIdOf(_local(jobId: 7)), 7);
      expect(jobIdOf(_local(lastJobId: 8)), 8);
      expect(jobIdOf(_local()), isNull);
    });
  });

  group('running a batch', () {
    test('carries on past a failure and says which one failed', () async {
      final result = await runBulk([_job(id: 1), _job(id: 2), _job(id: 3)], (e) async {
        if (e.upload!.jobId == 2) throw Exception('409');
      });
      expect(result.done, 2);
      expect(result.failed, hasLength(1));
      expect(result.failed.first.entry.upload!.jobId, 2);
    });

    test('does nothing and fails nothing for an empty selection', () async {
      final result = await runBulk([], (_) async => throw Exception('never'));
      expect(result.done, 0);
      expect(result.failed, isEmpty);
    });
  });

  group('telling the shopkeeper what happened', () {
    test('is plain when everything worked', () {
      expect(summarise('Discarded', const BulkResult(3, [])), 'Discarded 3 bills.');
      expect(summarise('Moved', const BulkResult(1, [])), 'Moved 1 bill.');
    });

    test('says what was left, and why, in words they would use', () {
      final text = summarise(
        'Discarded',
        BulkResult(2, [BulkFailure(_job(), Exception('x'))]),
        savedLeft: 2,
        readingLeft: 1,
      );
      expect(text, contains('Discarded 2 bills'));
      expect(text, contains("1 couldn't be discarded"));
      expect(text, contains('2 saved bills were left'));
      expect(text, contains('puts their stock back'));
      expect(text, contains('1 still being read'));
    });
  });

  test('a bill filed elsewhere keeps its identity', () {
    final u = UploadSummary(
      jobId: 5, status: 'done', sourceImage: '8/5.jpg', createdAt: DateTime(2026, 10, 8), folderId: 3);
    expect(u.withFolder(9).folderId, 9);
    expect(u.withFolder(null).folderId, isNull, reason: 'null must mean home, not "unchanged"');
    expect(u.withFolder(9).jobId, 5);
  });
}
