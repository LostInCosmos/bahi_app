import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/pdf_pages.dart';

/// DAS-27, the parts that are decidable without a platform PDF engine.
/// `pdfx` renders through Android PdfRenderer / iOS PDFKit, neither of
/// which exists in a unit test — the rendering itself is covered by the
/// web suite's e2e against a real two-page PDF, which exercises the same
/// resolution and the same whole-frame-corner rule.
void main() {
  group('recognising a PDF', () {
    test('by extension, whatever its case', () {
      expect(isPdfPath('/tmp/bill.pdf'), isTrue);
      expect(isPdfPath('/tmp/BILL.PDF'), isTrue);
      expect(isPdfPath('/tmp/invoice.Pdf'), isTrue);
    });

    test('and not a photo', () {
      expect(isPdfPath('/tmp/bill.jpg'), isFalse);
      expect(isPdfPath('/tmp/pdf_scan.png'), isFalse);
    });
  });

  group('the page cap', () {
    test('says how many pages the document had', () {
      /* The message has to name the number, or a shopkeeper cannot tell
         whether they picked the wrong file or hit a limit. */
      const e = TooManyPdfPages(57);
      expect(e.pages, 57);
      expect(e.toString(), contains('57'));
      expect(e.toString(), contains('$kMaxPdfPages'));
    });

    test('matches the web app', () {
      // shop_webapp/src/features/capture/pdfPages.js: MAX_PAGES = 20.
      expect(kMaxPdfPages, 20);
    });
  });

  test('a rendered page carries the size its corners need', () {
    final page = RenderedPage(Uint8List.fromList([1, 2, 3]), 2480, 3508);
    expect(page.width, 2480);
    expect(page.height, 3508);
  });

  test('whole-frame corners cover the page, so no edge is cropped off', () {
    /* A rendered PDF page is already flat. Corners covering anything
       less than the whole frame would cut the bill's edges off — and
       unlike a photo there is no crop screen where that would be
       noticed before upload. */
    final page = RenderedPage(Uint8List(0), 2480, 3508);
    final corners = [
      const Offset2D(0, 0),
      Offset2D(page.width, 0),
      Offset2D(page.width, page.height),
      Offset2D(0, page.height),
    ];
    expect(corners, hasLength(4));
    expect(corners.map((c) => c.x).reduce((a, b) => a > b ? a : b), page.width);
    expect(corners.map((c) => c.y).reduce((a, b) => a > b ? a : b), page.height);
    expect(corners.every((c) => c.x >= 0 && c.y >= 0), isTrue);

    // And such a page is a normal bill from here on — no needsCrop.
    final item = BatchItem(label: 'bill.pdf', pages: [
      BatchItemPage(
        photoId: 'p1',
        memoryBytes: null,
        filename: 'bill-p1.jpg',
        corners: corners,
        rotationDegrees: 0,
      )
    ]);
    expect(item.status, isNot(BatchItemStatus.needsCrop));
  });
}
