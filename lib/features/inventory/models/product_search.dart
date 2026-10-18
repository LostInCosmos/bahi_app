import 'product.dart';

// Python's `\w` on a str is "isalnum() or _": Unicode letters and numbers,
// not combining marks. Dart's `\w` is ASCII-only even with `unicode: true`,
// so the classes are spelled out — a Devanagari matra is dropped on both sides.
final _notWordOrSpace = RegExp(r'[^\p{L}\p{N}_\s]', unicode: true);
final _spaces = RegExp(r'\s+');

/// The server's `normalize_product_name`, step for step: lower-case, trim,
/// drop punctuation, collapse spaces. A search on the phone must normalise
/// exactly as the server does, or it would find different products than the
/// server's own search for the same text (DAS-94).
String normalizeProductName(String name) =>
    name.toLowerCase().trim().replaceAll(_notWordOrSpace, '').replaceAll(_spaces, ' ');

/// A shop's products, ready to search as the shopkeeper types. Each name is
/// normalised once, when the list arrives, not on every keystroke.
class ProductIndex {
  final List<ProductSummary> products;
  final List<String> _keys;

  ProductIndex(this.products) : _keys = [for (final p in products) normalizeProductName(p.name)];

  /// Every product whose name contains [query], in the server's order (by
  /// name) — the same rows `GET /inventory/products?q=` returns. Empty after
  /// normalising means every product, as on the server.
  List<ProductSummary> match(String query) {
    final key = normalizeProductName(query);
    if (key.isEmpty) return products;
    return [
      for (var i = 0; i < products.length; i++)
        if (_keys[i].contains(key)) products[i],
    ];
  }
}
