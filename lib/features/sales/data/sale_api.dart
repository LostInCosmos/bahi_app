part of '../../../core/api/api_client.dart';

extension SaleApi on ApiClient {
  Future<Map<String, dynamic>> createSale({
    String? buyerName,
    String? buyerGstin,
    required List<CartEntry> lineItems,
  }) async {
    final res = await _postJson('/sales', {
      'buyer_name': (buyerName == null || buyerName.isEmpty) ? null : buyerName,
      'buyer_gstin': (buyerGstin == null || buyerGstin.isEmpty) ? null : buyerGstin,
      'line_items': lineItems.map((c) => {'product_batch_id': c.productBatchId, 'qty': c.qty, 'rate': c.rate}).toList(),
    });
    return ApiClient._object(res);
  }

  Future<SaleDetail> getSaleDetail(int saleId) async =>
      SaleDetail.fromJson(ApiClient._object(await _get('/sales/$saleId')));

  Future<List<SaleSummary>> listSales({String? startDate, String? endDate}) async {
    final res = await _get('/sales', query: ApiClient._dateRange(startDate, endDate));
    return ApiClient._list(res).map((e) => SaleSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Uint8List> exportSalesExcel({String? startDate, String? endDate}) async => (await _get('/export/sales-excel',
          query: ApiClient._dateRange(startDate, endDate), timeout: ApiClient.transferTimeout))
      .bodyBytes;
}
