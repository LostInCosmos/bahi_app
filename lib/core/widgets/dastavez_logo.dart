import 'package:flutter/material.dart';

// The Dastavez mark: a document with a folded corner around a camera
// aperture. Drawn, not shipped as an image, so it stays sharp at any size.
// Geometry mirrors webapp_frontend/public/favicon.svg (64x64 viewBox).
const _navy = Color(0xFF13334E);
const _navyDark = Color(0xFF0C2238);
const _gold = Color(0xFFCC9153);
const _paper = Color(0xFFF7F3EC);

/// The bare mark. It is navy, so it needs a light surface behind it — use
/// [DastavezLogoTile] on the app's dark backgrounds.
class DastavezLogo extends StatelessWidget {
  const DastavezLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: const CustomPaint(painter: _LogoPainter()));
}

/// The mark on a cream rounded tile, readable on light and dark themes alike.
class DastavezLogoTile extends StatelessWidget {
  const DastavezLogoTile({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.14),
        decoration: BoxDecoration(color: _paper, borderRadius: BorderRadius.circular(size * 0.3)),
        child: DastavezLogo(size: size * 0.72),
      );
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);
    final fill = Paint()..style = PaintingStyle.fill;
    Paint stroke(double w) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeJoin = StrokeJoin.round
      ..color = _navyDark;

    final body = Path()
      ..moveTo(16, 4)
      ..lineTo(40, 4)
      ..lineTo(58, 22)
      ..lineTo(58, 50)
      ..quadraticBezierTo(58, 60, 48, 60)
      ..lineTo(16, 60)
      ..quadraticBezierTo(6, 60, 6, 50)
      ..lineTo(6, 14)
      ..quadraticBezierTo(6, 4, 16, 4)
      ..close();
    canvas.drawPath(body, fill..color = _navy);
    canvas.drawPath(body, stroke(1.5));

    final fold = Path()
      ..moveTo(40, 4)
      ..lineTo(58, 22)
      ..lineTo(40, 22)
      ..close();
    canvas.drawPath(fold, fill..color = _paper);
    canvas.drawPath(fold, stroke(1.2));

    canvas.drawCircle(const Offset(32, 33), 14.5, fill..color = _navy);
    const blades = [
      [(45.00, 33.00), (42.24, 41.00)],
      [(38.50, 44.26), (30.19, 45.87)],
      [(25.50, 44.26), (19.95, 37.87)],
      [(19.00, 33.00), (21.76, 25.00)],
      [(25.50, 21.74), (33.81, 20.13)],
      [(38.50, 21.74), (44.05, 28.13)],
    ];
    for (final b in blades) {
      final p = Path()
        ..moveTo(32, 33)
        ..lineTo(b[0].$1, b[0].$2)
        ..lineTo(b[1].$1, b[1].$2)
        ..close();
      canvas.drawPath(p, fill..color = _gold);
      canvas.drawPath(p, stroke(1));
    }
    canvas.drawCircle(const Offset(32, 33), 14.5, stroke(1.2));
  }

  @override
  bool shouldRepaint(_LogoPainter old) => false;
}
