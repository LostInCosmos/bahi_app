import 'dart:typed_data';

import '../../../core/api/api_client.dart';
import '../models/sale.dart';
import '../models/sale_totals.dart';

extension SaleApi on ApiClient {
  Future<Map<String, dynamic>> createSale({
    String? buyerName,
    String? buyerGstin,
    String? buyerPhone,
    String? doctorName,
    PaymentMode? paymentMode,
    required List<CartEntry> lineItems,
    Discount? discount,
  }) async {
    String? orNull(String? v) => (v == null || v.isEmpty) ? null : v;
    final res = await postJson('/sales', {
      'buyer_name': orNull(buyerName),
      'buyer_gstin': orNull(buyerGstin),
      // DAS-150. The server cleans the phone to 10 digits and refuses anything
      // else (422 "Enter a 10-digit phone number."). An older server ignores
      // all three, so the server ships first.
      if (orNull(buyerPhone) != null) 'buyer_phone': buyerPhone,
      if (orNull(doctorName) != null) 'doctor_name': doctorName,
      if (paymentMode != null) 'payment_mode': paymentMode.wire,
      // `rate` is GST-inclusive and a discount is sent as typed; the server
      // converts it to rupees and decides every total (DAS-111).
      if (Discount.wireOf(discount) != null) 'discount': Discount.wireOf(discount),
      // A line may ask for more than its batch holds (DAS-111): the shopkeeper
      // was told on the phone, and the server floors the batch at 0 and records
      // the shortfall. An older server ignores this and refuses as before.
      'allow_oversell': true,
      'line_items': lineItems
          .map((c) => {
                'product_batch_id': c.productBatchId,
                'qty': c.qty,
                'rate': c.rate,
                if (Discount.wireOf(c.discount) != null) 'discount': Discount.wireOf(c.discount),
              })
          .toList(),
    });
    return ApiClient.jsonObject(res);
  }

  Future<SaleDetail> getSaleDetail(int saleId) async =>
      SaleDetail.fromJson(ApiClient.jsonObject(await get('/sales/$saleId')));

  Future<List<SaleSummary>> listSales({String? startDate, String? endDate}) async {
    final res = await get('/sales', query: ApiClient.dateRange(startDate, endDate));
    return ApiClient.listOf(res, SaleSummary.fromJson);
  }

  Future<Uint8List> exportSalesExcel({String? startDate, String? endDate}) async => (await get('/export/sales-excel',
          query: ApiClient.dateRange(startDate, endDate), timeout: ApiClient.transferTimeout))
      .bodyBytes;
}
