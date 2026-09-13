import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Lets the user drag four corner handles onto a photographed bill's edges.
/// Mirrors the web app's canvas-based crop tool: no automatic edge/contour
/// detection, the user places the quad by hand and the server does the
/// perspective warp from whatever four points come back.
///
/// Corners are tracked in the *natural* (original photo) pixel space and
/// reported to [onCornersChanged] on every change, scaled back up from
/// whatever size the quad is actually being displayed at on screen.
///
/// Must be given bounded constraints in both axes (e.g. wrapped in an
/// `Expanded` inside a non-scrolling `Column`) — it fits the whole image
/// inside that box rather than scrolling, since a `GestureDetector`'s pan
/// recognizer competing with an ancestor `Scrollable` is exactly what made
/// dragging a corner feel unreliable before.
class CropCanvas extends StatefulWidget {
  final Uint8List imageBytes;
  final void Function(List<Offset> naturalCorners, Size naturalSize) onCornersChanged;

  const CropCanvas({super.key, required this.imageBytes, required this.onCornersChanged});

  @override
  State<CropCanvas> createState() => _CropCanvasState();
}

class _CropCanvasState extends State<CropCanvas> {
  // Generous hit-test radius in display pixels — well above Material's 48dp
  // minimum touch target, since precise dragging on a phone needs slack.
  static const double _touchRadius = 44;
  static const double _handleRadius = 14;
  static const double _handleRadiusActive = 18;

  ui.Image? _decodedImage;
  List<Offset> _corners = [];
  int? _draggingIndex;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant CropCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageBytes != widget.imageBytes) {
      _decode();
    }
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    const inset = 0.08;
    if (!mounted) return;
    setState(() {
      _decodedImage = image;
      _corners = [
        Offset(w * inset, h * inset),
        Offset(w * (1 - inset), h * inset),
        Offset(w * (1 - inset), h * (1 - inset)),
        Offset(w * inset, h * (1 - inset)),
      ];
    });
    _notify();
  }

  void _notify() {
    final image = _decodedImage;
    if (image == null) return;
    widget.onCornersChanged(
      List<Offset>.from(_corners),
      Size(image.width.toDouble(), image.height.toDouble()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _decodedImage;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(builder: (context, constraints) {
      final naturalW = image.width.toDouble();
      final naturalH = image.height.toDouble();
      final maxW = constraints.hasBoundedWidth ? constraints.maxWidth : naturalW;
      final maxH = constraints.hasBoundedHeight ? constraints.maxHeight : naturalH;
      // Fit the whole image inside the box (both axes) rather than scaling
      // to width alone — keeps every corner on screen with no scrolling.
      final scale = math.min(maxW / naturalW, maxH / naturalH);
      final displayW = naturalW * scale;
      final displayH = naturalH * scale;

      return Center(
        child: GestureDetector(
          onPanStart: (details) {
            final local = details.localPosition;
            int? best;
            double bestDist = _touchRadius;
            for (int i = 0; i < _corners.length; i++) {
              final displayPoint = _corners[i] * scale;
              final dist = (displayPoint - local).distance;
              if (dist < bestDist) {
                best = i;
                bestDist = dist;
              }
            }
            if (best != null) setState(() => _draggingIndex = best);
          },
          onPanUpdate: (details) {
            final index = _draggingIndex;
            if (index == null) return;
            final local = details.localPosition;
            final clampedX = local.dx.clamp(0.0, displayW).toDouble();
            final clampedY = local.dy.clamp(0.0, displayH).toDouble();
            setState(() {
              _corners[index] = Offset(clampedX / scale, clampedY / scale);
            });
            _notify();
          },
          onPanEnd: (_) => setState(() => _draggingIndex = null),
          child: SizedBox(
            width: displayW,
            height: displayH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                RawImage(image: image, width: displayW, height: displayH, fit: BoxFit.fill),
                CustomPaint(
                  size: Size(displayW, displayH),
                  painter: _QuadPainter(
                    displayPoints: _corners.map((c) => c * scale).toList(),
                    activeIndex: _draggingIndex,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> displayPoints;
  final int? activeIndex;
  _QuadPainter({required this.displayPoints, required this.activeIndex});

  @override
  void paint(Canvas canvas, Size size) {
    if (displayPoints.length != 4) return;

    final linePaint = Paint()
      ..color = const Color(0xFF22C55E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    final path = Path()..moveTo(displayPoints[0].dx, displayPoints[0].dy);
    for (final p in displayPoints.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, linePaint);

    final haloPaint = Paint()..color = const Color(0x3322C55E);
    final handleFill = Paint()..color = const Color(0xFF22C55E);
    final handleBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (int i = 0; i < displayPoints.length; i++) {
      final p = displayPoints[i];
      final isActive = i == activeIndex;
      final radius = isActive ? _CropCanvasState._handleRadiusActive : _CropCanvasState._handleRadius;
      // A larger translucent halo shows the actual (generous) touch area,
      // not just the small solid dot — makes the target legible at a glance.
      canvas.drawCircle(p, radius + 14, haloPaint);
      canvas.drawCircle(p, radius, handleFill);
      canvas.drawCircle(p, radius, handleBorder);
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) =>
      oldDelegate.displayPoints != displayPoints || oldDelegate.activeIndex != activeIndex;
}
