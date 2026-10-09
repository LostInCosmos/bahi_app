import 'batch_item.dart';
import 'upload_summary.dart';

/// Searching the bills on screen by the shop they are from, or by invoice
/// number.
///
/// Done entirely here, on what is loaded — no request per keystroke. "R" shows
/// every shop starting with R; "Ra" narrows that; each letter filters the
/// previous result, which is just the same rule applied to a longer query. A
/// shop name matches by its START, an invoice number by what it CONTAINS (the
/// part a shopkeeper remembers is rarely the beginning of "INV/2026/0418").

/// What was typed, ready to compare: trimmed and lower-cased. Empty means "no
/// search".
String normaliseSearch(String typed) => typed.trim().toLowerCase();

/// Whether a bill from [shop] numbered [invoiceNo] belongs in the results for
/// [query] (already [normaliseSearch]ed). A bill with neither — not read yet —
/// matches only the empty query: there is nothing to find it by.
bool matchesBillSearch(String query, {String? shop, String? invoiceNo}) {
  if (query.isEmpty) return true;
  final name = (shop ?? '').trim().toLowerCase();
  if (name.startsWith(query)) return true;
  final number = (invoiceNo ?? '').trim().toLowerCase();
  return number.contains(query);
}

extension UploadSearch on UploadSummary {
  bool matchesSearch(String query) => matchesBillSearch(query, shop: sellerName, invoiceNo: invoiceNo);
}

extension BatchItemSearch on BatchItem {
  /// The shop this phone's own bill is from, once it has been read.
  String? get shopName {
    final name = result?.invoice.sellerName.trim() ?? '';
    return name.isEmpty ? null : name;
  }

  bool matchesSearch(String query) =>
      matchesBillSearch(query, shop: shopName, invoiceNo: result?.invoice.invoiceNo);
}
