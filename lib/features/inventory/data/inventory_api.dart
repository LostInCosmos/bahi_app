part of '../../../core/api/api_client.dart';

extension InventoryApi on ApiClient {
  Future<List<ProductSummary>> searchProducts({String? q}) async {
    final query = <String, String>{};
    if (q != null && q.isNotEmpty) query['q'] = q;
    final res = await http.get(_uri('/inventory/products', query), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => ProductSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProductDetail> getProductDetail(int productId) async {
    final res = await http.get(_uri('/inventory/products/$productId'), headers: _authHeader);
    _checkOk(res);
    return ProductDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Creates a product that doesn't exist yet, plus its first batch — for a
  /// screen (like voice order "Add item") that expected to just pick an
  /// existing one from search but got a real not-in-inventory name instead.
  /// Throws ApiException(409) if the name already matches something in the
  /// catalog — the caller should have the shopkeeper pick that one instead.
  Future<ProductSummary> createProduct({
    required String name,
    required double mrp,
    required double quantity,
    required String unit,
    double gstPct = 0,
  }) async {
    final res = await http.post(
      _uri('/inventory/products'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'mrp': mrp,
        'quantity': quantity,
        'unit': unit,
        'gst_pct': gstPct,
      }),
    );
    _checkOk(res);
    return ProductSummary.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }
}
