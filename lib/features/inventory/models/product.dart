library;

class ProductSummary {
  final int id;
  final String name;
  final String? hsnCode;
  final String? pack;
  final double quantityOnHand;

  /// Net rate, MRP and expiry of this product's soonest-expiring in-stock
  /// batch (DAS-81) — the same batch a sale would actually draw from.
  /// Null together when no batch qualifies (no stock, or everything left is
  /// expired): never a mix from different batches.
  final double? netRate;
  final double? mrp;
  final String? expiryDate; // YYYY-MM-DD, already stripped of any time component

  ProductSummary({
    required this.id,
    required this.name,
    this.hsnCode,
    this.pack,
    required this.quantityOnHand,
    this.netRate,
    this.mrp,
    this.expiryDate,
  });

  factory ProductSummary.fromJson(Map<String, dynamic> json) => ProductSummary(
        id: json['id'] as int,
        name: json['name'] as String,
        hsnCode: json['hsn_code'] as String?,
        pack: json['pack'] as String?,
        quantityOnHand: (json['quantity_on_hand'] as num).toDouble(),
        netRate: (json['net_rate'] as num?)?.toDouble(),
        mrp: (json['mrp'] as num?)?.toDouble(),
        expiryDate: (json['expiry_date'] as String?)?.split('T').first,
      );
}

class ProductBatchInfo {
  final int id;
  final String? batchNo;
  final String? expiryDate; // YYYY-MM-DD, already stripped of any time component
  final double quantityOnHand;
  final double? mrp;
  final double gstPct;
  final bool isExpired;

  /// Where this batch came from (DAS-82) — null together for a batch with
  /// no linked purchase (added by hand, or predates this tracking).
  /// `sourceInvoiceId` is enough to open the full bill (InvoiceDetailScreen);
  /// name/no are just for the at-a-glance line here.
  final int? sourceInvoiceId;
  final String? vendorName;
  final String? invoiceNo;

  /// The deal this batch was actually bought on (DAS-82, widened) — `rate`
  /// through `freeScheme` come from the originating purchase line, same
  /// field names `GET /invoices/{id}` uses for a line item; `netRate` comes
  /// straight off the batch itself (its `purchase_rate`), so it can be
  /// present even in the shouldn't-happen case where no matching line is
  /// found — never assume it's null together with the other five.
  final double? netRate;
  final double? rate;
  final double? discountPct;
  final double? discountAmount;
  final double? freeQty;
  final String? freeScheme;

  ProductBatchInfo({
    required this.id,
    this.batchNo,
    this.expiryDate,
    required this.quantityOnHand,
    this.mrp,
    required this.gstPct,
    required this.isExpired,
    this.sourceInvoiceId,
    this.vendorName,
    this.invoiceNo,
    this.netRate,
    this.rate,
    this.discountPct,
    this.discountAmount,
    this.freeQty,
    this.freeScheme,
  });

  factory ProductBatchInfo.fromJson(Map<String, dynamic> json) => ProductBatchInfo(
        id: json['id'] as int,
        batchNo: json['batch_no'] as String?,
        expiryDate: (json['expiry_date'] as String?)?.split('T').first,
        quantityOnHand: (json['quantity_on_hand'] as num).toDouble(),
        mrp: (json['mrp'] as num?)?.toDouble(),
        gstPct: (json['gst_pct'] as num).toDouble(),
        isExpired: json['is_expired'] as bool,
        sourceInvoiceId: json['source_invoice_id'] as int?,
        vendorName: json['vendor_name'] as String?,
        invoiceNo: json['invoice_no'] as String?,
        netRate: (json['net_rate'] as num?)?.toDouble(),
        rate: (json['rate'] as num?)?.toDouble(),
        discountPct: (json['discount_pct'] as num?)?.toDouble(),
        discountAmount: (json['discount_amount'] as num?)?.toDouble(),
        freeQty: (json['free_qty'] as num?)?.toDouble(),
        freeScheme: json['free_scheme'] as String?,
      );
}

/// GET /inventory/products/{id} — batches already arrive FEFO-sorted
/// (soonest expiry first) from the backend.
class ProductDetail {
  final int id;
  final String name;
  final String? hsnCode;
  final String? pack;
  final double totalQuantity;
  final List<ProductBatchInfo> batches;

  ProductDetail({
    required this.id,
    required this.name,
    this.hsnCode,
    this.pack,
    required this.totalQuantity,
    required this.batches,
  });

  factory ProductDetail.fromJson(Map<String, dynamic> json) => ProductDetail(
        id: json['id'] as int,
        name: json['name'] as String,
        hsnCode: json['hsn_code'] as String?,
        pack: json['pack'] as String?,
        totalQuantity: (json['total_quantity'] as num).toDouble(),
        batches: (json['batches'] as List<dynamic>)
            .map((e) => ProductBatchInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
