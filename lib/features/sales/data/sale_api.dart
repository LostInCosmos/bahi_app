import 'dart:typed_data';

import '../../../core/api/api_client.dart';
import '../models/sale.dart';

extension SaleApi on ApiClient {
  Future<Map<String, dynamic>> createSale({
    String? buyerName,
    String? buyerGstin,
    required List<CartEntry> lineItems,
  }) async {
    final res = await postJson('/sales', {
      'buyer_name': (buyerName == null || buyerName.isEmpty) ? null : buyerName,
      'buyer_gstin': (buyerGstin == null || buyerGstin.isEmpty) ? null : buyerGstin,
      'line_items': lineItems.map((c) => {'product_batch_id': c.productBatchId, 'qty': c.qty, 'rate': c.rate}).toList(),
    });
    return ApiClient.jsonObject(res);
  }

  Future<SaleDetail> getSaleDetail(int saleId) async =>
      SaleDetail.fromJson(ApiClient.jsonObject(await get('/sales/$saleId')));

  Future<List<SaleSummary>> listSales({String? startDate, String? endDate}) async {
    final res = await get('/sales', query: ApiClient.dateRange(startDate, endDate));
    return ApiClient.jsonList(res).map((e) => SaleSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Uint8List> exportSalesExcel({String? startDate, String? endDate}) async => (await get('/export/sales-excel',
          query: ApiClient.dateRange(startDate, endDate), timeout: ApiClient.transferTimeout))
      .bodyBytes;
}
