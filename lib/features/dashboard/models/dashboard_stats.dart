import '../../../core/utils/format.dart';
import '../../inventory/models/product.dart';
import '../../inventory/models/product_search.dart';
import '../../invoice/models/invoice.dart';
import '../../sales/models/sale.dart';

// What the Home tab shows, worked out on the phone from the lists the other
// tabs already fetch: the sales list (GET /sales), the product list (GET
// /inventory/products, shared with Inventory and Sell) and the purchases list
// (GET /invoices). Pure functions over plain data, ported line for line from
// the web's dashboardStats.js (bahi_dashboard fdb8584) so the two show the
// same figures for the same shop and day (DAS-186). Dates are "YYYY-MM-DD"
// in local time, like the server's sale_date (the day in India).

/// The heads-up window beyond "expiring within a month" (the Inventory
/// chip's own rule, [expiringWithinAMonth]).
const kExpiringLaterDays = 90;

/// How many days the sales chart covers, today included.
const kTrendDays = 14;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// "YYYY-MM-01" of the month [today] is in.
String monthStart(DateTime today) => isoDate(DateTime(today.year, today.month, 1))!;

/// The first day the dashboard needs sales from: the earlier of the month's
/// start and the chart's first day.
String salesWindowStart(DateTime today) {
  final trend = isoDate(_addDays(today, -(kTrendDays - 1)))!;
  final month = monthStart(today);
  return trend.compareTo(month) < 0 ? trend : month;
}

class SalesSummary {
  final double todayTotal;
  final int todayCount;

  /// Null with no bill today.
  final double? averageBill;
  final double monthTotal;
  final int monthCount;

  const SalesSummary({
    required this.todayTotal,
    required this.todayCount,
    required this.averageBill,
    required this.monthTotal,
    required this.monthCount,
  });
}

/// Today's and this month's takings from the sales list.
SalesSummary salesSummary(List<SaleSummary> sales, DateTime today) {
  final todayIso = isoDate(today)!;
  final month = monthStart(today);
  var todayTotal = 0.0, monthTotal = 0.0;
  var todayCount = 0, monthCount = 0;
  for (final s in sales) {
    if (s.saleDate == todayIso) {
      todayTotal += s.grandTotal;
      todayCount += 1;
    }
    if (s.saleDate.compareTo(month) >= 0 && s.saleDate.compareTo(todayIso) <= 0) {
      monthTotal += s.grandTotal;
      monthCount += 1;
    }
  }
  return SalesSummary(
    todayTotal: todayTotal,
    todayCount: todayCount,
    averageBill: todayCount > 0 ? todayTotal / todayCount : null,
    monthTotal: monthTotal,
    monthCount: monthCount,
  );
}

class TrendDay {
  final String date;
  final double total;
  final bool isToday;
  const TrendDay(this.date, this.total, {this.isToday = false});

  @override
  bool operator ==(Object other) =>
      other is TrendDay && other.date == date && other.total == total && other.isToday == isToday;

  @override
  int get hashCode => Object.hash(date, total, isToday);

  @override
  String toString() => 'TrendDay($date, $total${isToday ? ', today' : ''})';
}

/// One bar per day for the last [kTrendDays] days, oldest first, today last.
List<TrendDay> salesTrend(List<SaleSummary> sales, DateTime today) {
  final byDay = <String, double>{};
  for (final s in sales) {
    byDay[s.saleDate] = (byDay[s.saleDate] ?? 0) + s.grandTotal;
  }
  return [
    for (var i = kTrendDays - 1; i >= 0; i--)
      () {
        final date = isoDate(_addDays(today, -i))!;
        return TrendDay(date, byDay[date] ?? 0, isToday: i == 0);
      }(),
  ];
}

/// Whole days from [today] to the product's soonest live expiry, or null
/// when it has none.
int? daysToExpiry(ProductSummary product, DateTime today) {
  final d = DateTime.tryParse(product.expiryDate ?? '');
  if (d == null) return null;
  return (_day(d).difference(_day(today)).inHours / 24).round();
}

enum AttentionWhy { expired, expiring, low, out }

class AttentionRow {
  final ProductSummary product;
  final AttentionWhy why;

  /// Days to expiry, when it has one.
  final int? days;
  const AttentionRow(this.product, this.why, this.days);
}

class StockWatch {
  /// In stock past its expiry.
  final int expired;
  final int expiringSoon;
  final int expiringLater;
  final int lowStock;
  final int outOfStock;
  final int products;

  /// Only products with a known purchase rate count, so the figure is an
  /// estimate and the tile says so. Null when none has one.
  final double? stockValue;
  final int valuedProducts;

  /// Expired first, then expiring within a month (soonest first), then
  /// running low (fewest first), then out of stock (by name).
  final List<AttentionRow> attention;

  const StockWatch({
    required this.expired,
    required this.expiringSoon,
    required this.expiringLater,
    required this.lowStock,
    required this.outOfStock,
    required this.products,
    required this.stockValue,
    required this.valuedProducts,
    required this.attention,
  });
}

int _byName(ProductSummary a, ProductSummary b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());

int _soonest(AttentionRow a, AttentionRow b) =>
    a.days! != b.days! ? a.days!.compareTo(b.days!) : _byName(a.product, b.product);

/// What the shelf says: counts for the tiles, and the rows for "needs
/// attention". The counts use the Inventory tab's own filters
/// ([expiringWithinAMonth], [runningLow], [outOfStock]), so a tile opens that
/// tab on exactly the list it counted.
StockWatch stockWatch(List<ProductSummary> products, DateTime today) {
  final soon = {for (final p in expiringWithinAMonth(products, today)) p.id};
  final expired = <AttentionRow>[], expiring = <AttentionRow>[];
  var later = 0, valued = 0;
  var stockValue = 0.0;
  for (final p in products) {
    final days = daysToExpiry(p, today);
    if (days != null && p.quantityOnHand > 0) {
      if (days < 0) {
        expired.add(AttentionRow(p, AttentionWhy.expired, days));
      } else if (soon.contains(p.id)) {
        expiring.add(AttentionRow(p, AttentionWhy.expiring, days));
      } else if (days <= kExpiringLaterDays) {
        later += 1;
      }
    }
    final rate = p.netRate;
    if (rate != null && p.quantityOnHand > 0) {
      stockValue += p.quantityOnHand * rate;
      valued += 1;
    }
  }
  expired.sort(_soonest);
  expiring.sort(_soonest);
  final low = [for (final p in runningLow(products)) AttentionRow(p, AttentionWhy.low, daysToExpiry(p, today))];
  final out = [for (final p in outOfStock(products)) AttentionRow(p, AttentionWhy.out, null)];
  return StockWatch(
    expired: expired.length,
    expiringSoon: expiring.length,
    expiringLater: later,
    lowStock: low.length,
    outOfStock: out.length,
    products: products.length,
    stockValue: valued > 0 ? stockValue : null,
    valuedProducts: valued,
    attention: [...expired, ...expiring, ...low, ...out],
  );
}

class PurchasesSummary {
  final double total;
  final int count;
  const PurchasesSummary(this.total, this.count);
}

/// This month's purchase bills: how many and for how much.
PurchasesSummary purchasesSummary(List<InvoiceSummary> invoices, DateTime today) {
  final month = monthStart(today);
  final todayIso = isoDate(today)!;
  var total = 0.0;
  var count = 0;
  for (final inv in invoices) {
    if (inv.invoiceDate.compareTo(month) >= 0 && inv.invoiceDate.compareTo(todayIso) <= 0) {
      total += inv.grandTotal;
      count += 1;
    }
  }
  return PurchasesSummary(total, count);
}
