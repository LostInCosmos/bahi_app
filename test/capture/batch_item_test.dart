import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';

BatchItemPage _page(String? photoId) => BatchItemPage(
      photoId: photoId,
      memoryBytes: null,
      filename: 'bill.jpg',
      corners: const [Offset2D(1, 2), Offset2D(30, 2), Offset2D(30, 40), Offset2D(1, 40)],
      rotationDegrees: 90,
    );

void main() {
  test('a bill that never finished uploading is restored with its saved photos', () {
    final item = BatchItem(label: 'Photo 3', pages: [_page('7_a'), _page('7_b')])
      ..status = BatchItemStatus.failed
      ..errorMessage = 'Upload failed';

    final restored = BatchItem.fromJson(item.toJson())!;

    expect(restored.isUploaded, isFalse);
    expect(restored.pages.map((p) => p.photoId), ['7_a', '7_b']);
    expect(restored.pages.first.corners.last.y, 40);
    expect(restored.pages.first.rotationDegrees, 90);
    // A failed upload comes back ready to be uploaded again, not stuck failed.
    expect(restored.status, BatchItemStatus.preparing);
  });

  test('a page held only in memory is not saved, and an item with nothing left is dropped', () {
    final item = BatchItem(label: 'Photo 1', pages: [_page(null)]);
    expect(item.isPersistable, isFalse);
    expect(BatchItem.fromJson(item.toJson()), isNull);
  });

  test('an uploaded bill mid-extraction resumes the same job', () {
    final item = BatchItem(label: 'Photo 2', pages: [])
      ..sourceImages = ['7/abc.jpg']
      ..status = BatchItemStatus.processing
      ..jobId = 42
      ..lastJobId = 42;

    final restored = BatchItem.fromJson(item.toJson())!;

    expect(restored.status, BatchItemStatus.processing);
    expect(restored.jobId, 42);
    expect(restored.sourceImages, ['7/abc.jpg']);
  });

  test('processing with no job yet rewinds to ready, so it is submitted again', () {
    final item = BatchItem(label: 'Photo 4', pages: [])
      ..sourceImages = ['7/def.jpg']
      ..status = BatchItemStatus.processing;

    expect(BatchItem.fromJson(item.toJson())!.status, BatchItemStatus.ready);
  });

  test('batches saved before pending photos existed still load', () {
    final legacy = {
      'label': 'Photo 1',
      'sourceImages': ['7/old.jpg'],
      'status': 'pendingConfirm',
      'jobId': null,
    };
    final restored = BatchItem.fromJson(legacy)!;
    expect(restored.status, BatchItemStatus.pendingConfirm);
    expect(restored.pages, isEmpty);
  });
}
