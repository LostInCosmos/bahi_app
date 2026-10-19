/// How numbers, money, dates and counts are written for the shopkeeper.
///
/// These used to be re-implemented per screen — three different `_fmt`s, a
/// `_numText`, and `'₹${x.toStringAsFixed(2)}'` some thirty times — so the
/// same quantity could read differently on two screens. One place, one
/// spelling.
library;

/// `₹1,234.50` without the thousands separator: `₹1234.50`. Two decimals
/// always, so a column of amounts lines up.
String rupees(num amount) => '₹${amount.toStringAsFixed(2)}';

/// A number for a text field or a label: a whole number plain (`12`), a
/// fraction as Dart prints it (`12.5`). Null is empty. This is the shape
/// numbers arrive in from the server, so writing one back never nudges the
/// cursor, and `double.tryParse` reads it back exactly.
String numText(double? value) {
  if (value == null) return '';
  return value == value.truncateToDouble() ? value.toInt().toString() : value.toString();
}

/// A number for display only: a whole number plain, a fraction to two places.
String wholeOrFixed2(double value) =>
    value == value.truncateToDouble() ? value.toInt().toString() : value.toStringAsFixed(2);

/// A percentage: `12%`, `12.5%` — whole rates plain, since GST slabs are.
String percent(double value) => '${wholeOrFixed2(value)}%';

/// A quantity: whole numbers only, as stock is counted.
String qty(num value) => value.toStringAsFixed(0);

/// `1 bill`, `3 bills`. [pluralWord] when it is not just an `s`.
String plural(int n, String word, [String? pluralWord]) => '$n ${n == 1 ? word : (pluralWord ?? '${word}s')}';

/// `YYYY-MM-DD` for a request or a label; null stays null.
String? isoDate(DateTime? date) => date?.toIso8601String().split('T').first;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `04 Oct 2026`.
String shortDate(DateTime when) => '${when.day.toString().padLeft(2, '0')} ${_months[when.month - 1]} ${when.year}';

/// `mm:ss` of a running recording.
String formatElapsed(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
