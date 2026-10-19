import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/utils/format.dart';

/// How numbers are written for the shopkeeper. `numText` matters most: the
/// review form writes a number into a field with it and reads it back with
/// `double.tryParse`, so the round trip must be exact (see
/// `test/invoice/save_round_trip_test.dart`).
void main() {
  test('numText: whole numbers plain, fractions as Dart prints them, null empty', () {
    expect(numText(12), '12');
    expect(numText(12.0), '12');
    expect(numText(12.5), '12.5');
    expect(numText(0), '0');
    expect(numText(null), '');
    for (final v in [1.0, 2.25, 1234.5678, 0.1]) {
      expect(double.tryParse(numText(v)), v, reason: 'round trip of $v');
    }
  });

  test('money always has two decimals so columns line up', () {
    expect(rupees(12), '₹12.00');
    expect(rupees(12.5), '₹12.50');
    expect(rupees(0), '₹0.00');
  });

  test('display numbers and percentages', () {
    expect(wholeOrFixed2(5), '5');
    expect(wholeOrFixed2(5.129), '5.13');
    expect(percent(12), '12%');
    expect(percent(2.5), '2.50%');
    expect(qty(3.0), '3');
  });

  test('plural', () {
    expect(plural(1, 'bill'), '1 bill');
    expect(plural(0, 'bill'), '0 bills');
    expect(plural(2, 'batch', 'batches'), '2 batches');
  });

  test('dates', () {
    expect(isoDate(DateTime(2026, 10, 4, 13, 5)), '2026-10-04');
    expect(isoDate(null), isNull);
    expect(shortDate(DateTime(2026, 10, 4)), '04 Oct 2026');
    expect(formatElapsed(const Duration(seconds: 65)), '01:05');
  });
}
