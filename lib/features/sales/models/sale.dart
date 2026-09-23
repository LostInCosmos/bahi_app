library;

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
        productName: json['product_name'] as String,
        qty: (json['qty'] as num).toDouble(),
        rate: (json['rate'] as num).toDouble(),
        gstPct: (json['gst_pct'] as num).toDouble(),
        cgstAmount: (json['cgst_amount'] as num).toDouble(),
        sgstAmount: (json['sgst_amount'] as num).toDouble(),
        lineAmount: (json['line_amount'] as num).toDouble(),
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
        id: json['id'] as int,
        saleNo: json['sale_no'] as String,
        saleDate: (json['sale_date'] as String).split('T').first,
        buyerName: json['buyer_name'] as String?,
        grandTotal: (json['grand_total'] as num).toDouble(),
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
        id: json['id'] as int,
        saleNo: json['sale_no'] as String,
        saleDate: (json['sale_date'] as String).split('T').first,
        buyerName: json['buyer_name'] as String?,
        buyerGstin: json['buyer_gstin'] as String?,
        subtotal: (json['subtotal'] as num).toDouble(),
        totalCgst: (json['total_cgst'] as num).toDouble(),
        totalSgst: (json['total_sgst'] as num).toDouble(),
        grandTotal: (json['grand_total'] as num).toDouble(),
        lineItems: (json['line_items'] as List<dynamic>)
            .map((e) => SaleLineItemDetail.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
