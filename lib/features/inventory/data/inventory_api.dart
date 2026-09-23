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
}
