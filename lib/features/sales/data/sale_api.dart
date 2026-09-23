part of '../../../core/api/api_client.dart';

extension SaleApi on ApiClient {
  Future<Map<String, dynamic>> createSale({
    String? buyerName,
    String? buyerGstin,
    required List<CartEntry> lineItems,
  }) async {
    final res = await http.post(
      _uri('/sales'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'buyer_name': (buyerName == null || buyerName.isEmpty) ? null : buyerName,
        'buyer_gstin': (buyerGstin == null || buyerGstin.isEmpty) ? null : buyerGstin,
        'line_items': lineItems
            .map((c) => {'product_batch_id': c.productBatchId, 'qty': c.qty, 'rate': c.rate})
            .toList(),
      }),
    );
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<SaleDetail> getSaleDetail(int saleId) async {
    final res = await http.get(_uri('/sales/$saleId'), headers: _authHeader);
    _checkOk(res);
    return SaleDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<SaleSummary>> listSales({String? startDate, String? endDate}) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    final res = await http.get(_uri('/sales', query), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => SaleSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Uint8List> exportSalesExcel({String? startDate, String? endDate}) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    final res = await http.get(_uri('/export/sales-excel', query), headers: _authHeader);
    _checkOk(res);
    return res.bodyBytes;
  }
}
