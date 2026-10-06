import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

/// A PDF bill, rendered into page images (DAS-27).
///
/// Distributors email PDF invoices, and the only way in before this was
/// to print one and photograph it. Rendering on the device rather than
/// on the server is deliberate: `preprocessing.py` has already
/// OOM-killed the API container once, and a PDF bomb is an easy way to
/// do it again. A phone rendering its own document can only hurt
/// itself.
///
/// Mirrors `shop_webapp/src/features/capture/pdfPages.js`, including the
/// resolution and the page cap, so the two clients produce comparable
/// images from the same file.
///
/// ## Why 300 dpi
///
/// A rendered page goes through `/invoices/preprocess` like any photo,
/// which warps it to its corners. Even with whole-page corners that
/// warp resamples every pixel, and on crisp digital text it is
/// expensive — measured on a synthetic bill, it costs 51% of edge
/// sharpness and lifts black text from 9/255 to 71/255.
///
/// Rendering larger buys most of that back, because the warp then
/// downsamples rather than smears. 300 dpi reaches ~85% of what an
/// unwarped path would store, while staying under the server's 4000px
/// source cap. Removing the warp for already-flat pages is the
/// remaining 15% and needs a backend change — noted on DAS-27,
/// deliberately not done.
const double _dpi = 300;

/// A PDF point is 1/72 inch, by definition.
const double _pdfPointsPerInch = 72;
const double _scale = _dpi / _pdfPointsPerInch;

/// Beyond this a document is almost certainly not one bill, and
/// rendering it would lock up the phone.
const int kMaxPdfPages = 20;

bool isPdfPath(String path) => path.toLowerCase().endsWith('.pdf');

/// One rendered page: the JPEG bytes and the size they were drawn at.
///
/// The size comes back because the caller has to give each page
/// whole-frame corners — a rendered page is already flat, so there is
/// nothing to crop, and corners covering anything less would cut the
/// edges off the bill.
class RenderedPage {
  final Uint8List bytes;
  final double width;
  final double height;
  const RenderedPage(this.bytes, this.width, this.height);
}

class TooManyPdfPages implements Exception {
  final int pages;
  const TooManyPdfPages(this.pages);
  @override
  String toString() =>
      'This PDF has $pages pages; up to $kMaxPdfPages can be read at once.';
}

/// Render every page of [path].
///
/// [onProgress] fires per page — a ten-page document takes long enough
/// on a cheap phone that silence reads as a hang.
Future<List<RenderedPage>> renderPdf(
  String path, {
  void Function(int done, int total)? onProgress,
}) async {
  final doc = await PdfDocument.openFile(path);
  try {
    if (doc.pagesCount > kMaxPdfPages) {
      throw TooManyPdfPages(doc.pagesCount);
    }
    final out = <RenderedPage>[];
    for (var n = 1; n <= doc.pagesCount; n++) {
      final page = await doc.getPage(n);
      try {
        final image = await page.render(
          width: page.width * _scale,
          height: page.height * _scale,
          format: PdfPageImageFormat.jpeg,
          // White, not transparent: a PDF page has no background of its
          // own, and an unpainted one encodes to JPEG as black.
          backgroundColor: '#FFFFFF',
        );
        if (image == null) continue;
        out.add(RenderedPage(image.bytes, image.width!.toDouble(), image.height!.toDouble()));
      } finally {
        // Closed per page rather than at the end: twenty full-size
        // pages held at once is hundreds of MB, which a cheap Android
        // will not survive.
        await page.close();
      }
      onProgress?.call(n, doc.pagesCount);
    }
    return out;
  } finally {
    await doc.close();
  }
}
