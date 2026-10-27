import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// [data] as a QR code a phone camera can scan: black on white whatever the
/// app's theme, with the white margin scanners need. Drawn on the phone; no
/// image is fetched or stored.
class QrCodeView extends StatelessWidget {
  final String data;
  final double size;
  const QrCodeView(this.data, {super.key, this.size = 160});

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    return Semantics(
      label: 'QR code for $data',
      image: true,
      child: CustomPaint(size: Size.square(size), painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;
  _QrPainter(this.image);

  /// The margin, in modules, that the QR standard asks for around the code.
  static const _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final cells = image.moduleCount + 2 * _quiet;
    final cell = size.shortestSide / cells;
    final dark = Paint()..color = Colors.black;
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        // A hair over one cell, so no seams show between neighbours.
        canvas.drawRect(Rect.fromLTWH((col + _quiet) * cell, (row + _quiet) * cell, cell + 0.5, cell + 0.5), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
