library;

import '../../../core/utils/json.dart';

/// One line the shopkeeper has added to the sale in progress, before it's
/// submitted — mirrors the web app's in-memory `cart` array.
class CartEntry {
  final int productBatchId;
  final String productName;
  final String? batchNo;
  final double qty;
  final double rate;
  final double gstPct;

  CartEntry({
    required this.productBatchId,
    required this.productName,
    this.batchNo,
    required this.qty,
    required this.rate,
    required this.gstPct,
  });

  double get lineAmount => qty * rate;
}

class SaleLineItemDetail {
  final String productName;
  final double qty;
  final double rate;
  final double gstPct;
  final double cgstAmount;
  final double sgstAmount;
  final double lineAmount;

  SaleLineItemDetail({
    required this.productName,
    required this.qty,
    required this.rate,
    required this.gstPct,
    required this.cgstAmount,
    required this.sgstAmount,
    required this.lineAmount,
  });

  factory SaleLineItemDetail.fromJson(Map<String, dynamic> json) => SaleLineItemDetail(
        productName: json.strReq('product_name'),
        qty: json.dblReq('qty'),
        rate: json.dblReq('rate'),
        gstPct: json.dblReq('gst_pct'),
        cgstAmount: json.dblReq('cgst_amount'),
        sgstAmount: json.dblReq('sgst_amount'),
        lineAmount: json.dblReq('line_amount'),
      );
}

/// One row of GET /sales — the sales-history list.
class SaleSummary {
  final int id;
  final String saleNo;
  final String saleDate;
  final String? buyerName;
  final double grandTotal;

  SaleSummary({
    required this.id,
    required this.saleNo,
    required this.saleDate,
    this.buyerName,
    required this.grandTotal,
  });

  factory SaleSummary.fromJson(Map<String, dynamic> json) => SaleSummary(
        id: json.intReq('id'),
        saleNo: json.strReq('sale_no'),
        saleDate: json.dateOnlyReq('sale_date'),
        buyerName: json.str('buyer_name'),
        grandTotal: json.dblReq('grand_total'),
      );
}

/// GET /sales/{id} — used for the post-sale receipt.
class SaleDetail {
  final int id;
  final String saleNo;
  final String saleDate;
  final String? buyerName;
  final String? buyerGstin;
  final double subtotal;
  final double totalCgst;
  final double totalSgst;
  final double grandTotal;
  final List<SaleLineItemDetail> lineItems;

  SaleDetail({
    required this.id,
    required this.saleNo,
    required this.saleDate,
    this.buyerName,
    this.buyerGstin,
    required this.subtotal,
    required this.totalCgst,
    required this.totalSgst,
    required this.grandTotal,
    required this.lineItems,
  });

  factory SaleDetail.fromJson(Map<String, dynamic> json) => SaleDetail(
        id: json.intReq('id'),
        saleNo: json.strReq('sale_no'),
        saleDate: json.dateOnlyReq('sale_date'),
        buyerName: json.str('buyer_name'),
        buyerGstin: json.str('buyer_gstin'),
        subtotal: json.dblReq('subtotal'),
        totalCgst: json.dblReq('total_cgst'),
        totalSgst: json.dblReq('total_sgst'),
        grandTotal: json.dblReq('grand_total'),
        lineItems: json.listOf('line_items', SaleLineItemDetail.fromJson),
      );
}
