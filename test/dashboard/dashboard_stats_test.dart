import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/dashboard/models/dashboard_stats.dart';
import 'package:gst_bill_app/features/inventory/models/product.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';

/// The web's dashboardStats.test.js (bahi_dashboard fdb8584), ported case for
/// case so the app and the web show the same figures (DAS-186).

final today = DateTime(2026, 11, 14); // 14 Nov 2026

var _id = 0;
SaleSummary _sale(String date, double total) =>
    SaleSummary(id: ++_id, saleNo: 'S$_id', saleDate: date, grandTotal: total);

InvoiceSummary _inv(String date, double total) => InvoiceSummary(
    id: ++_id,
    vendorGstin: '',
    vendorName: 'V',
    invoiceNo: 'I$_id',
    invoiceDate: date,
    grandTotal: total,
    reviewed: true,
    extractionMethod: 'llm');

ProductSummary _p(String name, double quantityOnHand, [String? expiryDate, double? netRate]) =>
    ProductSummary(id: ++_id, name: name, quantityOnHand: quantityOnHand, expiryDate: expiryDate, netRate: netRate);

void main() {
  group('salesSummary', () {
    test("separates today from the month and averages today's bills", () {
      final s = salesSummary([
        _sale('2026-11-14', 100),
        _sale('2026-11-14', 300),
        _sale('2026-11-02', 50),
        _sale('2026-10-31', 999),
      ], today);
      expect(s.todayTotal, 400);
      expect(s.todayCount, 2);
      expect(s.averageBill, 200);
      expect(s.monthTotal, 450);
      expect(s.monthCount, 3);
    });
    test('has no average without a bill', () {
      expect(salesSummary([], today).averageBill, isNull);
    });
  });

  test('salesTrend gives fourteen days ending today, zero where nothing sold', () {
    final days = salesTrend([_sale('2026-11-14', 10), _sale('2026-11-01', 5), _sale('2026-10-31', 7)], today);
    expect(days, hasLength(14));
    expect(days.first, const TrendDay('2026-11-01', 5));
    expect(days.last, const TrendDay('2026-11-14', 10, isToday: true));
    expect(days[1].total, 0);
  });

  test('salesWindowStart is the earlier of the month start and the chart start', () {
    expect(salesWindowStart(DateTime(2026, 11, 14)), '2026-11-01');
    expect(salesWindowStart(DateTime(2026, 11, 3)), '2026-10-21');
  });

  group('stockWatch', () {
    test('counts expiring, low and out, and orders attention by urgency', () {
      final w = stockWatch([
        _p('Soon', 10, '2026-12-01', 2),
        _p('Later', 10, '2027-01-20'),
        _p('Fine', 10, '2027-11-01', 3),
        _p('Low', 2),
        _p('Out', 0),
        _p('Lowest', 1),
      ], today);
      expect(w.expiringSoon, 1);
      expect(w.expiringLater, 1);
      expect(w.lowStock, 2);
      expect(w.outOfStock, 1);
      expect([for (final a in w.attention) '${a.why.name}:${a.product.name}'],
          ['expiring:Soon', 'low:Lowest', 'low:Low', 'out:Out']);
      expect(w.stockValue, 10 * 2 + 10 * 3);
      expect(w.valuedProducts, 2);
    });
    test('has no stock value when no product carries a purchase rate', () {
      expect(stockWatch([_p('A', 3)], today).stockValue, isNull);
    });
    test('puts expired stock first and counts it apart from expiring', () {
      final w = stockWatch([_p('Gone', 4, '2026-11-01'), _p('Soon', 10, '2026-11-20')], today);
      expect(w.expired, 1);
      expect(w.expiringSoon, 1);
      expect([for (final a in w.attention) '${a.why.name}:${a.product.name}'], ['expired:Gone', 'expiring:Soon', 'low:Gone']);
    });
        test('ignores expiry on an out-of-stock product', () {
      expect(stockWatch([_p('Gone', 0, '2026-11-20')], today).expiringSoon, 0);
    });
  });

  test('daysToExpiry counts whole days from today', () {
    expect(daysToExpiry(_p('A', 1, '2026-11-15'), today), 1);
    expect(daysToExpiry(_p('A', 1), today), isNull);
    expect(daysToExpiry(_p('A', 1, '2026-11-15'), DateTime(2026, 11, 14, 23, 59)), 1, reason: 'the time of day does not count');
  });

  test("purchasesSummary sums this month's bills", () {
    final p = purchasesSummary([_inv('2026-11-03', 420), _inv('2026-10-30', 1)], today);
    expect(p.total, 420);
    expect(p.count, 1);
  });
}
