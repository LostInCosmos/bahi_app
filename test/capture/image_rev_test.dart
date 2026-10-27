import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';

// DAS-150: the photo's revision after our team rotates it (DAS-72) comes on
// the job, not inside extraction_meta. Read from the meta it was always 0, so
// the capture grid's thumbnail kept showing the photo from before the turn.

Map<String, dynamic> _job({int? imageRev}) => {
      'job_id': 5,
      'status': 'done',
      if (imageRev != null) 'image_rev': imageRev,
      'result': {
        'invoice': {
          'seller_name': 'ACME',
          'invoice_no': 'A-9',
          'invoice_date': '2026-08-01',
          'line_items': [],
          'totals': {'grand_total': 112},
        },
        'extraction_meta': {'source_image': '8/5.jpg', 'method': 'llm'},
        'issues': [],
      },
    };

void main() {
  test("the job's image_rev reaches the result the thumbnail draws from", () {
    expect(ExtractionJob.fromJson(_job(imageRev: 3)).result!.meta.imageRev, 3);
    expect(ExtractionJob.fromJson(_job()).result!.meta.imageRev, 0, reason: 'never rotated, or an older server');
  });

  test('the capture batch keeps it across a restart', () {
    final item = BatchItem(label: 'Photo 1', pages: [])
      ..sourceImages = ['8/5.jpg'] // uploaded: a bill with no photo is not restored
      ..status = BatchItemStatus.pendingConfirm
      ..result = ExtractionJob.fromJson(_job(imageRev: 2)).result;
    final restored = BatchItem.fromJson(item.toJson());
    expect(restored!.result!.meta.imageRev, 2);
  });
}
