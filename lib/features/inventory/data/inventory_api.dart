import '../../../core/api/api_client.dart';
import '../../../core/utils/json.dart';
import '../models/product.dart';

/// The whole product list and the `ETag` it came with, to send back next time.
class ProductListPage {
  final List<ProductSummary> products;
  final String? etag;
  const ProductListPage(this.products, {this.etag});
}

extension InventoryApi on ApiClient {
  Future<List<ProductSummary>> searchProducts({String? q}) async {
    final res = await get('/inventory/products', query: {if (q != null && q.isNotEmpty) 'q': q});
    return ApiClient.listOf(res, ProductSummary.fromJson);
  }

  /// The shop's whole list (DAS-94), conditionally: with [ifNoneMatch] (the
  /// `etag` of the list already held) an unchanged list is a `304` with no
  /// body, returned as null — no bytes on cellular, no parse (DAS-105). A
  /// server without ETags answers the full list every time, as before.
  Future<ProductListPage?> fetchProducts({String? ifNoneMatch}) async {
    final res = await get('/inventory/products', ifNoneMatch: ifNoneMatch);
    if (res.statusCode == 304) return null;
    return ProductListPage(ApiClient.listOf(res, ProductSummary.fromJson), etag: res.headers['etag']);
  }

  Future<ProductDetail> getProductDetail(int productId) async =>
      ProductDetail.fromJson(ApiClient.jsonObject(await get('/inventory/products/$productId')));

  /// Corrects one batch's MRP (DAS-111): what a sale prefills and every list
  /// shows. It changes only this batch, and the purchase bill keeps what it
  /// printed. Throws ApiException: 422 `bad_mrp`, 404 for a batch that is gone
  /// (merged by our team, DAS-93) or another shop's.
  Future<double> setBatchMrp(int batchId, double mrp) async {
    final res = await patchJson('/inventory/batches/$batchId/mrp', {'mrp': mrp});
    final body = ApiClient.jsonObject(res);
    // The answer lists every batch changed: `{batches: [{id, mrp, mrp_edited}]}`.
    final changed = body.listOf('batches', (j) => j).where((j) => j.integer('id') == batchId);
    return (changed.isEmpty ? body : changed.first).dblReq('mrp');
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
    final res = await postJson('/inventory/products', {
      'name': name,
      'mrp': mrp,
      'quantity': quantity,
      'unit': unit,
      'gst_pct': gstPct,
    });
    return ProductSummary.fromJson(ApiClient.jsonObject(res));
  }
}
