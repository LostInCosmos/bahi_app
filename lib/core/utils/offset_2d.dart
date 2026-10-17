/// Minimal (x, y) pair — avoids pulling in dart:ui's Offset in files that
/// otherwise have no Flutter widget dependency. Crop corners are stored and
/// sent as these.
class Offset2D {
  final double x;
  final double y;
  const Offset2D(this.x, this.y);
}
