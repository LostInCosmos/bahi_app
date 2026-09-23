library;

class ProductSummary {
  final int id;
  final String name;
  final String? hsnCode;
  final String? pack;
  final double quantityOnHand;

  ProductSummary({
    required this.id,
    required this.name,
    this.hsnCode,
    this.pack,
    required this.quantityOnHand,
  });

  factory ProductSummary.fromJson(Map<String, dynamic> json) => ProductSummary(
        id: json['id'] as int,
        name: json['name'] as String,
        hsnCode: json['hsn_code'] as String?,
        pack: json['pack'] as String?,
        quantityOnHand: (json['quantity_on_hand'] as num).toDouble(),
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

  ProductBatchInfo({
    required this.id,
    this.batchNo,
    this.expiryDate,
    required this.quantityOnHand,
    this.mrp,
    required this.gstPct,
    required this.isExpired,
  });

  factory ProductBatchInfo.fromJson(Map<String, dynamic> json) => ProductBatchInfo(
        id: json['id'] as int,
        batchNo: json['batch_no'] as String?,
        expiryDate: (json['expiry_date'] as String?)?.split('T').first,
        quantityOnHand: (json['quantity_on_hand'] as num).toDouble(),
        mrp: (json['mrp'] as num?)?.toDouble(),
        gstPct: (json['gst_pct'] as num).toDouble(),
        isExpired: json['is_expired'] as bool,
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
