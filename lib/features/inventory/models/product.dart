library;

import '../../../core/utils/json.dart';

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
        id: json.intReq('id'),
        name: json.strReq('name'),
        hsnCode: json.str('hsn_code'),
        pack: json.str('pack'),
        quantityOnHand: json.dblReq('quantity_on_hand'),
        netRate: json.dbl('net_rate'),
        mrp: json.dbl('mrp'),
        expiryDate: json.dateOnly('expiry_date'),
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
        id: json.intReq('id'),
        batchNo: json.str('batch_no'),
        expiryDate: json.dateOnly('expiry_date'),
        quantityOnHand: json.dblReq('quantity_on_hand'),
        mrp: json.dbl('mrp'),
        gstPct: json.dblReq('gst_pct'),
        isExpired: json.boolReq('is_expired'),
        sourceInvoiceId: json.integer('source_invoice_id'),
        vendorName: json.str('vendor_name'),
        invoiceNo: json.str('invoice_no'),
        netRate: json.dbl('net_rate'),
        rate: json.dbl('rate'),
        discountPct: json.dbl('discount_pct'),
        discountAmount: json.dbl('discount_amount'),
        freeQty: json.dbl('free_qty'),
        freeScheme: json.str('free_scheme'),
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
        id: json.intReq('id'),
        name: json.strReq('name'),
        hsnCode: json.str('hsn_code'),
        pack: json.str('pack'),
        totalQuantity: json.dblReq('total_quantity'),
        batches: json.listOf('batches', ProductBatchInfo.fromJson),
      );
}
