part of '../../../core/api/api_client.dart';

extension InventoryApi on ApiClient {
  Future<List<ProductSummary>> searchProducts({String? q}) async {
    final res = await _get('/inventory/products', query: {if (q != null && q.isNotEmpty) 'q': q});
    return ApiClient._list(res).map((e) => ProductSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ProductDetail> getProductDetail(int productId) async =>
      ProductDetail.fromJson(ApiClient._object(await _get('/inventory/products/$productId')));

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
    final res = await _postJson('/inventory/products', {
      'name': name,
      'mrp': mrp,
      'quantity': quantity,
      'unit': unit,
      'gst_pct': gstPct,
    });
    return ProductSummary.fromJson(ApiClient._object(res));
  }
}
