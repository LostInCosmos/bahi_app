import 'package:flutter_test/flutter_test.dart';
import 'package:gst_bill_app/features/sales/models/sale_totals.dart';

/// The worked cases Backend agreed for DAS-111 (rate is GST-inclusive;
/// half-up to the paisa; cgst = sgst = round(tax / 2); taxable = grand − tax).
SaleLineInput _l(double qty, double rate, double gst, [Discount? d]) =>
    SaleLineInput(qty: qty, rate: rate, gstPct: gst, discount: d);

void main() {
  test('1: 2 x 100 at 12%, no discount: a sale at MRP totals exactly MRP', () {
    final t = computeSale([_l(2, 100, 12)]);
    expect(t.grandTotal, 200.00);
    expect(t.lines[0].cgstPaise, 1071);
    expect(t.lines[0].sgstPaise, 1071);
    expect(t.taxable, 178.58);
    expect(t.hasError, isFalse);
  });

  test('2: item 10% off 3 x 33.33 at 5%', () {
    final t = computeSale([_l(3, 33.33, 5, const Discount(DiscountKind.percentage, 10))]);
    expect(t.lines[0].grossPaise, 9999);
    expect(t.itemDiscounts, 10.00);
    expect(t.grandTotal, 89.99);
    expect(t.lines[0].cgstPaise, 214);
    expect(t.taxable, 85.71);
  });

  test('3: three lines, whole-sale 10 off, the extra paisa goes to the first', () {
    final t = computeSale([_l(1, 100, 12), _l(1, 100, 12), _l(1, 100, 12)],
        saleDiscount: const Discount(DiscountKind.amount, 10));
    expect([for (final l in t.lines) l.shareOfSaleDiscountPaise], [334, 333, 333]);
    expect([for (final l in t.lines) l.totalPaise], [9666, 9667, 9667]);
    expect([for (final l in t.lines) l.cgstPaise], [518, 518, 518]);
    expect(t.grandTotal, 290.00);
    expect(t.taxable, 258.92);
  });

  test('4: whole-sale 5% over 99.99 at 18% and 50.01 at 5%', () {
    final t = computeSale([_l(1, 99.99, 18), _l(1, 50.01, 5)],
        saleDiscount: const Discount(DiscountKind.percentage, 5));
    expect(t.saleDiscount, 7.50);
    expect([for (final l in t.lines) l.shareOfSaleDiscountPaise], [500, 250]);
    expect([for (final l in t.lines) l.totalPaise], [9499, 4751]);
    expect([for (final l in t.lines) l.cgstPaise], [725, 113]);
    expect(t.grandTotal, 142.50);
    expect(t.cgst, 8.38);
    expect(t.sgst, 8.38);
    expect(t.taxable, 125.74);
  });

  test('5: item 20 off an 80 line, plus a 40 line, whole-sale 7.50', () {
    final t = computeSale([_l(1, 80, 12, const Discount(DiscountKind.amount, 20)), _l(1, 40, 12)],
        saleDiscount: const Discount(DiscountKind.amount, 7.5));
    expect([for (final l in t.lines) l.shareOfSaleDiscountPaise], [450, 300]);
    expect([for (final l in t.lines) l.totalPaise], [5550, 3700]);
    expect([for (final l in t.lines) l.cgstPaise], [297, 198]);
    expect(t.grandTotal, 92.50);
    expect(t.cgst, 4.95);
    expect(t.taxable, 82.60);
  });

  test('the header always adds up: taxable + cgst + sgst = grand total', () {
    final t = computeSale([_l(3, 33.33, 5), _l(7, 12.35, 18), _l(1, 0.01, 28)],
        saleDiscount: const Discount(DiscountKind.percentage, 3.3));
    expect((t.taxable + t.cgst + t.sgst).toStringAsFixed(2), t.grandTotal.toStringAsFixed(2));
    expect(t.lines.fold(0, (s, l) => s + l.shareOfSaleDiscountPaise), t.saleDiscountPaise);
  });

  test('a discount out of range is reported and counts as none', () {
    final t = computeSale([_l(2, 100, 12, const Discount(DiscountKind.amount, 250))],
        saleDiscount: const Discount(DiscountKind.percentage, 120));
    expect(t.itemErrors[0], 'More than the line (₹200.00)');
    expect(t.saleError, 'A discount can be at most 100%');
    expect(t.grandTotal, 200.00);
    expect(t.hasError, isTrue);
  });

  test('a whole-sale amount above the sale is refused', () {
    final t = computeSale([_l(1, 85, 12)], saleDiscount: const Discount(DiscountKind.amount, 400));
    expect(t.saleError, 'More than the sale (₹85.00)');
  });

  test('a free line (100% off) totals zero and is allowed', () {
    final t = computeSale([_l(1, 85, 12, const Discount(DiscountKind.percentage, 100))]);
    expect(t.grandTotal, 0);
    expect(t.hasError, isFalse);
  });

  test('wire shape: nothing is sent for no discount, the spelling is the server\'s', () {
    expect(Discount.wireOf(null), isNull);
    expect(Discount.wireOf(const Discount(DiscountKind.amount, 0)), isNull);
    expect(Discount.wireOf(const Discount(DiscountKind.percentage, 10)), {'type': 'percentage', 'value': 10.0});
    expect(Discount.wireOf(const Discount(DiscountKind.amount, 15)), {'type': 'amount', 'value': 15.0});
  });
}
