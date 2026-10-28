import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/sales/models/sale_date.dart';

void main() {
  test('for now any past date: from the start of GST up to today, never after', () {
    final w = saleDateWindow(DateTime(2026, 10, 28, 17, 5));
    expect(w.first, DateTime(2017, 7, 1));
    expect(w.last, DateTime(2026, 10, 28), reason: 'no future dates (the user); the time of day is dropped');
  });

  group('with the limits switched back on', () {
    test('back 30 days, up to today', () {
      final w = saleDateWindow(DateTime(2026, 10, 28, 17, 5), limits: true);
      expect(w.first, DateTime(2026, 9, 28));
      expect(w.last, DateTime(2026, 10, 28));
    });

    test('never before 1 April of the financial year', () {
      expect(saleDateWindow(DateTime(2026, 4, 10), limits: true).first, DateTime(2026, 4, 1));
      expect(saleDateWindow(DateTime(2027, 3, 31), limits: true).first, DateTime(2027, 3, 1));
    });
  });

  test('the financial year runs April to March', () {
    expect(financialYearStart(DateTime(2027, 3, 31)), DateTime(2026, 4, 1));
    expect(financialYearStart(DateTime(2026, 4, 1)), DateTime(2026, 4, 1));
  });
}
