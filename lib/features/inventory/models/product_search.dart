import '../../../core/utils/format.dart';
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
///
/// It also knows which products share a name. Since ADR-020 the server keeps
/// the same brand in another pack, or at another price, as a product of its
/// own, so a shop can hold two "PROMINENT CHARCOAL" (60GM at ₹140, 100GM at
/// ₹185). Wherever a name stands alone, [qualifier] says what tells such a
/// product from its namesakes — and says nothing for the common case, a name
/// the shop has once. Worked out here, once per list, not per row.
class ProductIndex {
  final List<ProductSummary> products;
  final List<String> _keys;
  final Map<int, ProductSummary> _byId;

  /// Only products whose name another product shares have an entry; a value
  /// is the pack, failing that the MRP, failing that nothing (null) — see
  /// [qualifierFor].
  final Map<int, String?> _qualifiers;

  ProductIndex(List<ProductSummary> products)
      : this._(products, [for (final p in products) normalizeProductName(p.name)]);

  ProductIndex._(this.products, this._keys)
      : _byId = {for (final p in products) p.id: p},
        _qualifiers = _sharedNameQualifiers(products, _keys);

  static Map<int, String?> _sharedNameQualifiers(List<ProductSummary> products, List<String> keys) {
    final byKey = <String, List<ProductSummary>>{};
    for (var i = 0; i < products.length; i++) {
      (byKey[keys[i]] ??= []).add(products[i]);
    }
    return {
      for (final group in byKey.values)
        if (group.length > 1)
          for (final p in group) p.id: qualifierFor(p, group),
    };
  }

  /// What tells [p] from the other products in [namesakes] (a group of
  /// products with its name, [p] included): its pack when no namesake prints
  /// the same pack, else its MRP when the list carries one (the soonest
  /// in-stock batch's), else its pack anyway, else nothing.
  static String? qualifierFor(ProductSummary p, List<ProductSummary> namesakes) {
    final pack = p.pack?.trim();
    final hasPack = pack != null && pack.isNotEmpty;
    // "60GM" and "60 gm" are the same pack.
    String packKey(String s) => normalizeProductName(s).replaceAll(' ', '');
    final key = hasPack ? packKey(pack) : null;
    final packUnique = hasPack && !namesakes.any((o) => o.id != p.id && o.pack != null && packKey(o.pack!) == key);
    if (packUnique) return pack;
    if (p.mrp != null) return '₹${wholeOrFixed2(p.mrp!)}';
    return hasPack ? pack : null;
  }

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

  ProductSummary? byId(int id) => _byId[id];

  /// True when another product of the shop has this product's name.
  bool sharesName(int id) => _qualifiers.containsKey(id);

  /// Shown beside the name only when the shop has the name more than once:
  /// the pack ("60GM"), or the MRP ("₹185") when the pack is missing or the same.
  /// Null for a name the shop has once — the display stays as it was.
  String? qualifier(int id) => _qualifiers[id];

  /// [name] with its [qualifier], for a plain string: `PROMINENT CHARCOAL · 60GM`.
  String label(int id, String name) {
    final q = qualifier(id);
    return q == null ? name : '$name · $q';
  }
}
