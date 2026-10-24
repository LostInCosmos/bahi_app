library;

import '../../../core/utils/json.dart';
import 'sale_totals.dart';

/// One line the shopkeeper has added to the sale in progress, before it's
/// submitted — mirrors the web app's in-memory `cart` array.
class CartEntry {
  final int productBatchId;
  final String productName;
  final String? batchNo;
  final double qty;
  final double rate;
  final double gstPct;

  /// Off this line (DAS-111): as typed, `₹` off the line or a percentage of it.
  /// The server converts it; [lineAmount] stays what the customer would pay
  /// without it.
  final Discount? discount;

  CartEntry({
    required this.productBatchId,
    required this.productName,
    this.batchNo,
    required this.qty,
    required this.rate,
    required this.gstPct,
    this.discount,
  });

  double get lineAmount => qty * rate;

  SaleLineInput get input => SaleLineInput(qty: qty, rate: rate, gstPct: gstPct, discount: discount);
}

class SaleLineItemDetail {
  final String productName;
  final double qty;
  final double rate;
  final double gstPct;
  final double cgstAmount;
  final double sgstAmount;

  /// What the customer paid for this line before any discount (qty × rate).
  final double lineAmount;

  /// ₹ off this line (DAS-111): its own discount, and its share of a whole-sale
  /// one. 0 on a server that has no discounts, and on a sale made before them.
  final double discountAmount;
  final double saleDiscountShare;

  SaleLineItemDetail({
    required this.productName,
    required this.qty,
    required this.rate,
    required this.gstPct,
    required this.cgstAmount,
    required this.sgstAmount,
    required this.lineAmount,
    this.discountAmount = 0,
    this.saleDiscountShare = 0,
  });

  double get discountTotal => discountAmount + saleDiscountShare;

  factory SaleLineItemDetail.fromJson(Map<String, dynamic> json) => SaleLineItemDetail(
        productName: json.strReq('product_name'),
        qty: json.dblReq('qty'),
        rate: json.dblReq('rate'),
        gstPct: json.dblReq('gst_pct'),
        cgstAmount: json.dblReq('cgst_amount'),
        sgstAmount: json.dblReq('sgst_amount'),
        lineAmount: json.dblReq('line_amount'),
        discountAmount: json.dblOr('discount_amount'),
        saleDiscountShare: json.dblOr('sale_discount_share'),
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

  /// ₹ off the whole sale, and everything taken off (items + whole sale).
  /// 0 from a server without discounts (DAS-111).
  final double discountAmount;
  final double totalDiscount;
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
    this.discountAmount = 0,
    this.totalDiscount = 0,
    required this.lineItems,
  });

  /// The GST inside [grandTotal].
  double get tax => totalCgst + totalSgst;

  /// Before any discount: what the lines add up to.
  double get itemsTotal => lineItems.fold(0.0, (sum, li) => sum + li.lineAmount);

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
        discountAmount: json.dblOr('discount_amount'),
        totalDiscount: json.dblOr('total_discount'),
        lineItems: json.listOf('line_items', SaleLineItemDetail.fromJson),
      );
}
