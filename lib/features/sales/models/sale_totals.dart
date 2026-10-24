/// What a sale in progress comes to, worked out the way the server works it
/// out, so the checkout screen shows the number the receipt will show.
///
/// The price a shop types is GST-inclusive (DAS-111). A discount lowers what
/// the customer pays, and the GST inside the price follows the discounted
/// amount. Everything is worked in whole paise, so there is no float drift
/// and the split of a whole-sale discount across lines sums exactly.
///
/// This is a preview. The server converts the discounts and is the only
/// place a sale's numbers are decided; `test/sales/sale_totals_test.dart`
/// pins the cases the Backend agreed (DAS-111).
library;

/// How a discount was typed. The wire spelling is the server's
/// (`percentage` | `amount`).
enum DiscountKind {
  amount('amount'),
  percentage('percentage');

  final String wire;
  const DiscountKind(this.wire);
}

class Discount {
  final DiscountKind kind;
  final double value;
  const Discount(this.kind, this.value);

  /// The JSON object a request carries; null when there is nothing to send.
  static Map<String, dynamic>? wireOf(Discount? d) =>
      d == null || d.value <= 0 ? null : {'type': d.kind.wire, 'value': d.value};
}

/// One line as the maths sees it.
class SaleLineInput {
  final double qty;
  final double rate;
  final double gstPct;
  final Discount? discount;
  const SaleLineInput({required this.qty, required this.rate, required this.gstPct, this.discount});
}

class LineTotals {
  final int grossPaise;
  final int itemDiscountPaise;
  final int shareOfSaleDiscountPaise;
  final int cgstPaise;
  final int sgstPaise;

  const LineTotals({
    required this.grossPaise,
    required this.itemDiscountPaise,
    required this.shareOfSaleDiscountPaise,
    required this.cgstPaise,
    required this.sgstPaise,
  });

  int get netPaise => grossPaise - itemDiscountPaise;
  int get totalPaise => netPaise - shareOfSaleDiscountPaise;

  double get gross => grossPaise / 100;
  double get itemDiscount => itemDiscountPaise / 100;
  double get total => totalPaise / 100;
}

class SaleTotals {
  final List<LineTotals> lines;
  final int saleDiscountPaise;

  /// Why the discounts cannot be applied, or null. [itemErrors] is by line.
  final Map<int, String> itemErrors;
  final String? saleError;

  const SaleTotals({
    required this.lines,
    required this.saleDiscountPaise,
    required this.itemErrors,
    required this.saleError,
  });

  bool get hasError => itemErrors.isNotEmpty || saleError != null;

  int get _gross => lines.fold(0, (s, l) => s + l.grossPaise);
  int get _itemDiscounts => lines.fold(0, (s, l) => s + l.itemDiscountPaise);
  int get _cgst => lines.fold(0, (s, l) => s + l.cgstPaise);
  int get _sgst => lines.fold(0, (s, l) => s + l.sgstPaise);
  int get _grand => lines.fold(0, (s, l) => s + l.totalPaise);

  double get items => _gross / 100;
  double get itemDiscounts => _itemDiscounts / 100;
  double get saleDiscount => saleDiscountPaise / 100;
  double get grandTotal => _grand / 100;
  double get cgst => _cgst / 100;
  double get sgst => _sgst / 100;

  /// The GST that is inside [grandTotal].
  double get tax => (_cgst + _sgst) / 100;
  double get taxable => (_grand - _cgst - _sgst) / 100;
}

int _paise(double rupees) => (rupees * 100 + 1e-9).round();

/// `value`% of [basePaise], to the paisa, half up.
int _percentOf(int basePaise, double value) => (basePaise * value / 100 + 1e-9).round();

String _rupeesText(int paise) => '₹${(paise / 100).toStringAsFixed(2)}';

/// Returns the ₹ a discount comes to against [basePaise], or null with
/// [error] set when it is out of range.
({int paise, String? error}) _resolve(Discount? d, int basePaise, String of) {
  if (d == null || d.value == 0) return (paise: 0, error: null);
  if (d.value.isNaN || d.value < 0) return (paise: 0, error: 'Enter a discount of 0 or more');
  if (d.kind == DiscountKind.percentage) {
    if (d.value > 100) return (paise: 0, error: 'A discount can be at most 100%');
    return (paise: _percentOf(basePaise, d.value), error: null);
  }
  final paise = _paise(d.value);
  if (paise > basePaise) return (paise: 0, error: 'More than $of (${_rupeesText(basePaise)})');
  return (paise: paise, error: null);
}

/// The sale's totals. A discount that is out of range counts as no discount
/// in the numbers and is reported in [SaleTotals.itemErrors] / `saleError`.
SaleTotals computeSale(List<SaleLineInput> inputs, {Discount? saleDiscount}) {
  final gross = [for (final l in inputs) _paise(l.qty * l.rate)];
  final itemDisc = <int>[];
  final itemErrors = <int, String>{};
  for (var i = 0; i < inputs.length; i++) {
    final r = _resolve(inputs[i].discount, gross[i], 'the line');
    itemDisc.add(r.paise);
    if (r.error != null) itemErrors[i] = r.error!;
  }
  final net = [for (var i = 0; i < inputs.length; i++) gross[i] - itemDisc[i]];
  final netSum = net.fold(0, (s, n) => s + n);

  final sale = _resolve(saleDiscount, netSum, 'the sale');
  final shares = _split(sale.paise, net);

  final lines = <LineTotals>[];
  for (var i = 0; i < inputs.length; i++) {
    final total = net[i] - shares[i];
    final tax = total * inputs[i].gstPct / (100 + inputs[i].gstPct);
    final half = (tax / 2 + 1e-9).round();
    lines.add(LineTotals(
      grossPaise: gross[i],
      itemDiscountPaise: itemDisc[i],
      shareOfSaleDiscountPaise: shares[i],
      cgstPaise: half,
      sgstPaise: half,
    ));
  }
  return SaleTotals(lines: lines, saleDiscountPaise: sale.paise, itemErrors: itemErrors, saleError: sale.error);
}

/// [total] paise shared out in proportion to [weights], largest remainder,
/// ties to the earlier line — the shares always add up to [total].
List<int> _split(int total, List<int> weights) {
  final sum = weights.fold(0, (s, w) => s + w);
  if (total == 0 || sum == 0) return List.filled(weights.length, 0);
  final floors = <int>[];
  final remainders = <double>[];
  for (final w in weights) {
    final exact = total * w / sum;
    final floor = exact.floor();
    floors.add(floor);
    remainders.add(exact - floor);
  }
  var left = total - floors.fold(0, (s, f) => s + f);
  final order = List.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final c = remainders[b].compareTo(remainders[a]);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final i in order) {
    if (left <= 0) break;
    floors[i] += 1;
    left -= 1;
  }
  return floors;
}
