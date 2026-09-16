/// Data models mirroring backend/app/schemas.py — kept in lockstep with the
/// invoice JSON schema so the review form can round-trip an extraction
/// result straight into a save request.
library models;

class LineItem {
  String productName;
  String? pack;
  String? batchNo;
  String? expiry;
  String? hsnCode;
  double qty;
  double? freeQty;
  String? freeScheme;
  double? mrp;
  double rate;
  double? discountPct;
  double? discountAmount;
  double gstPct;
  // cgst_pct/sgst_pct/igst_pct are always server-derived — never edited,
  // captured only so a re-save/revalidate round trip doesn't silently drop
  // what the server already worked out.
  double? cgstPct;
  double? sgstPct;
  double? igstPct;
  double? cgstAmount;
  double? sgstAmount;
  double? igstAmount;
  double lineAmount;

  LineItem({
    this.productName = "",
    this.pack,
    this.batchNo,
    this.expiry,
    this.hsnCode,
    this.qty = 0,
    this.freeQty,
    this.freeScheme,
    this.mrp,
    this.rate = 0,
    this.discountPct,
    this.discountAmount,
    this.gstPct = 0,
    this.cgstPct,
    this.sgstPct,
    this.igstPct,
    this.cgstAmount,
    this.sgstAmount,
    this.igstAmount,
    this.lineAmount = 0,
  });

  factory LineItem.fromJson(Map<String, dynamic> json) => LineItem(
        productName: json['product_name'] as String? ?? "",
        pack: json['pack'] as String?,
        batchNo: json['batch_no'] as String?,
        expiry: json['expiry'] as String?,
        hsnCode: json['hsn_code'] as String?,
        qty: (json['qty'] as num?)?.toDouble() ?? 0,
        freeQty: (json['free_qty'] as num?)?.toDouble(),
        freeScheme: json['free_scheme'] as String?,
        mrp: (json['mrp'] as num?)?.toDouble(),
        rate: (json['rate'] as num?)?.toDouble() ?? 0,
        discountPct: (json['discount_pct'] as num?)?.toDouble(),
        discountAmount: (json['discount_amount'] as num?)?.toDouble(),
        gstPct: (json['gst_pct'] as num?)?.toDouble() ?? 0,
        cgstPct: (json['cgst_pct'] as num?)?.toDouble(),
        sgstPct: (json['sgst_pct'] as num?)?.toDouble(),
        igstPct: (json['igst_pct'] as num?)?.toDouble(),
        cgstAmount: (json['cgst_amount'] as num?)?.toDouble(),
        sgstAmount: (json['sgst_amount'] as num?)?.toDouble(),
        igstAmount: (json['igst_amount'] as num?)?.toDouble(),
        lineAmount: (json['line_amount'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'product_name': productName,
        'pack': pack,
        'batch_no': batchNo,
        'expiry': expiry,
        'hsn_code': hsnCode,
        'qty': qty,
        'free_qty': freeQty,
        'free_scheme': freeScheme,
        'mrp': mrp,
        'rate': rate,
        'discount_pct': discountPct,
        'discount_amount': discountAmount,
        'gst_pct': gstPct,
        'cgst_pct': cgstPct,
        'sgst_pct': sgstPct,
        'igst_pct': igstPct,
        'cgst_amount': cgstAmount,
        'sgst_amount': sgstAmount,
        'igst_amount': igstAmount,
        'line_amount': lineAmount,
      };
}

class Totals {
  double subtotal;
  double? totalDiscount;
  double totalCgst;
  double totalSgst;
  double? totalIgst;
  double? roundOff;
  double grandTotal;

  Totals({
    this.subtotal = 0,
    this.totalDiscount,
    this.totalCgst = 0,
    this.totalSgst = 0,
    this.totalIgst,
    this.roundOff,
    this.grandTotal = 0,
  });

  factory Totals.fromJson(Map<String, dynamic> json) => Totals(
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
        totalDiscount: (json['total_discount'] as num?)?.toDouble(),
        totalCgst: (json['total_cgst'] as num?)?.toDouble() ?? 0,
        totalSgst: (json['total_sgst'] as num?)?.toDouble() ?? 0,
        totalIgst: (json['total_igst'] as num?)?.toDouble(),
        roundOff: (json['round_off'] as num?)?.toDouble(),
        grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'subtotal': subtotal,
        'total_discount': totalDiscount,
        'total_cgst': totalCgst,
        'total_sgst': totalSgst,
        'total_igst': totalIgst,
        'round_off': roundOff,
        'grand_total': grandTotal,
      };
}

class InvoiceData {
  String sellerName;
  String sellerGstin;
  String? sellerAddress;
  String? sellerPhone;
  String? sellerDlNo;
  String? buyerName;
  String? buyerDlNo;
  String invoiceNo;
  String invoiceDate; // YYYY-MM-DD
  String? invoiceType;
  String? placeOfSupply;
  List<LineItem> lineItems;
  Totals totals;

  InvoiceData({
    this.sellerName = "",
    this.sellerGstin = "",
    this.sellerAddress,
    this.sellerPhone,
    this.sellerDlNo,
    this.buyerName,
    this.buyerDlNo,
    this.invoiceNo = "",
    this.invoiceDate = "",
    this.invoiceType,
    this.placeOfSupply,
    List<LineItem>? lineItems,
    Totals? totals,
  })  : lineItems = lineItems ?? [],
        totals = totals ?? Totals();

  factory InvoiceData.fromJson(Map<String, dynamic> json) => InvoiceData(
        sellerName: json['seller_name'] as String? ?? "",
        sellerGstin: json['seller_gstin'] as String? ?? "",
        sellerAddress: json['seller_address'] as String?,
        sellerPhone: json['seller_phone'] as String?,
        sellerDlNo: json['seller_dl_no'] as String?,
        buyerName: json['buyer_name'] as String?,
        buyerDlNo: json['buyer_dl_no'] as String?,
        invoiceNo: json['invoice_no'] as String? ?? "",
        invoiceDate: json['invoice_date'] as String? ?? "",
        invoiceType: json['invoice_type'] as String?,
        placeOfSupply: json['place_of_supply'] as String?,
        lineItems: (json['line_items'] as List<dynamic>? ?? [])
            .map((e) => LineItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        totals: Totals.fromJson(json['totals'] as Map<String, dynamic>? ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'seller_name': sellerName,
        'seller_gstin': sellerGstin,
        'seller_address': sellerAddress,
        'seller_phone': sellerPhone,
        'seller_dl_no': sellerDlNo,
        'buyer_name': buyerName,
        'buyer_dl_no': buyerDlNo,
        'invoice_no': invoiceNo,
        'invoice_date': invoiceDate,
        'invoice_type': invoiceType,
        'place_of_supply': placeOfSupply,
        'line_items': lineItems.map((e) => e.toJson()).toList(),
        'totals': totals.toJson(),
      };
}

class ExtractionMeta {
  String sourceImage;
  // Extra pages of the same continued bill, in order after sourceImage —
  // empty for the overwhelming majority of single-page bills. See
  // CaptureScreen's multi-page capture flow.
  List<String> extraSourceImages;
  String method; // "template" | "llm"
  int? templateId;
  double? confidence;
  bool reviewedByUser;
  // True when seller_name/address/dl_no were filled in from an already-
  // known Vendor row rather than fresh OCR — informational only.
  bool vendorKnown;

  ExtractionMeta({
    required this.sourceImage,
    List<String>? extraSourceImages,
    required this.method,
    this.templateId,
    this.confidence,
    this.reviewedByUser = false,
    this.vendorKnown = false,
  }) : extraSourceImages = extraSourceImages ?? [];

  factory ExtractionMeta.fromJson(Map<String, dynamic> json) => ExtractionMeta(
        sourceImage: json['source_image'] as String? ?? "",
        extraSourceImages: (json['extra_source_images'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
        method: json['method'] as String? ?? "llm",
        templateId: json['template_id'] as int?,
        confidence: (json['confidence'] as num?)?.toDouble(),
        reviewedByUser: json['reviewed_by_user'] as bool? ?? false,
        vendorKnown: json['vendor_known'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'source_image': sourceImage,
        'extra_source_images': extraSourceImages,
        'method': method,
        'template_id': templateId,
        'confidence': confidence,
        'reviewed_by_user': reviewedByUser,
        'vendor_known': vendorKnown,
      };
}

/// A field-attributed validation finding from backend/app/validation.py —
/// "field" is either a header/totals key ("seller_gstin", "totals.subtotal")
/// or "line_items[N].xxx", "severity" is "error" or "warning".
class ValidationIssue {
  final String field;
  final String severity;
  final String message;
  // Set only for the GSTIN-ambiguity issue — the review screen offers these
  // as tap-to-fill choices instead of making the shopkeeper retype all 15
  // characters (see backend validation.resolve_gstin_candidates).
  final List<String>? candidates;

  ValidationIssue({required this.field, required this.severity, required this.message, this.candidates});

  factory ValidationIssue.fromJson(Map<String, dynamic> json) => ValidationIssue(
        field: json['field'] as String,
        severity: json['severity'] as String,
        message: json['message'] as String,
        candidates: (json['candidates'] as List?)?.cast<String>(),
      );

  Map<String, dynamic> toJson() => {'field': field, 'severity': severity, 'message': message, 'candidates': candidates};

  bool get isError => severity == 'error';
}

/// POST /invoices/revalidate — re-checks a reviewed-but-not-yet-saved
/// invoice against the same server-side rules extract()/save() use,
/// without persisting anything or touching Gemini.
class RevalidateResult {
  InvoiceData invoice;
  List<ValidationIssue> issues;

  RevalidateResult({required this.invoice, required this.issues});

  factory RevalidateResult.fromJson(Map<String, dynamic> json) => RevalidateResult(
        invoice: InvoiceData.fromJson(json['invoice'] as Map<String, dynamic>),
        issues: (json['issues'] as List<dynamic>? ?? [])
            .map((e) => ValidationIssue.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ExtractionResult {
  InvoiceData invoice;
  ExtractionMeta meta;
  List<ValidationIssue> issues;

  ExtractionResult({required this.invoice, required this.meta, required this.issues});

  factory ExtractionResult.fromJson(Map<String, dynamic> json) => ExtractionResult(
        invoice: InvoiceData.fromJson(json['invoice'] as Map<String, dynamic>),
        meta: ExtractionMeta.fromJson(json['extraction_meta'] as Map<String, dynamic>),
        issues: (json['issues'] as List<dynamic>? ?? [])
            .map((e) => ValidationIssue.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  // Only needed to persist a batch item's result across an app kill —
  // never sent to the server (the server response is what fromJson reads).
  Map<String, dynamic> toJson() => {
        'invoice': invoice.toJson(),
        'extraction_meta': meta.toJson(),
        'issues': issues.map((i) => i.toJson()).toList(),
      };

  /// Used when the backend retried extraction once and the result still
  /// didn't match the invoice schema — routes straight to a blank,
  /// manual-entry review form instead of leaving the user stuck on an error.
  factory ExtractionResult.blank(String sourceImage, String message) => ExtractionResult(
        invoice: InvoiceData(),
        meta: ExtractionMeta(sourceImage: sourceImage, method: 'llm', reviewedByUser: false),
        issues: [ValidationIssue(field: 'invoice', severity: 'warning', message: message)],
      );
}

/// GET /invoices/extract/{jobId} — extraction now runs in a background
/// worker instead of inline during POST /invoices/extract, so the client
/// submits a job (see ApiClient.submitExtraction) and polls this until
/// status is no longer 'pending'/'processing'.
class ExtractionJob {
  final int jobId;
  final String status; // 'pending' | 'processing' | 'done' | 'failed'
  final ExtractionResult? result; // set iff status == 'done'
  final String? errorKind; // 'structural_validation_failed' | 'generic' — set iff status == 'failed'
  final String? errorMessage;
  final String? sourceImage;
  final List<String>? extraSourceImages;

  ExtractionJob({
    required this.jobId,
    required this.status,
    this.result,
    this.errorKind,
    this.errorMessage,
    this.sourceImage,
    this.extraSourceImages,
  });

  bool get isTerminal => status == 'done' || status == 'failed';

  factory ExtractionJob.fromJson(Map<String, dynamic> json) {
    final error = json['error'] as Map<String, dynamic>?;
    return ExtractionJob(
      jobId: json['job_id'] as int,
      status: json['status'] as String,
      result: json['result'] != null ? ExtractionResult.fromJson(json['result'] as Map<String, dynamic>) : null,
      errorKind: error?['kind'] as String?,
      errorMessage: error?['message'] as String?,
      sourceImage: error?['source_image'] as String?,
      extraSourceImages: (error?['extra_source_images'] as List?)?.cast<String>(),
    );
  }
}

class InvoiceSummary {
  final int id;
  final String vendorGstin;
  final String vendorName;
  final String invoiceNo;
  final String invoiceDate;
  final double grandTotal;
  final bool reviewed;
  final String extractionMethod;

  InvoiceSummary({
    required this.id,
    required this.vendorGstin,
    required this.vendorName,
    required this.invoiceNo,
    required this.invoiceDate,
    required this.grandTotal,
    required this.reviewed,
    required this.extractionMethod,
  });

  factory InvoiceSummary.fromJson(Map<String, dynamic> json) => InvoiceSummary(
        id: json['id'] as int,
        vendorGstin: json['vendor_gstin'] as String,
        vendorName: json['vendor_name'] as String,
        invoiceNo: json['invoice_no'] as String,
        invoiceDate: (json['invoice_date'] as String).split('T').first,
        grandTotal: (json['grand_total'] as num).toDouble(),
        reviewed: json['reviewed'] as bool,
        extractionMethod: json['extraction_method'] as String,
      );
}

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

/// One candidate product offered for an ambiguous/not_found voice-order
/// line — shown in a bottom sheet so the shopkeeper taps the right one.
class VoiceLineCandidate {
  final int id;
  final String name;
  final String? strength;
  final String? unit;

  VoiceLineCandidate({required this.id, required this.name, this.strength, this.unit});

  factory VoiceLineCandidate.fromJson(Map<String, dynamic> json) => VoiceLineCandidate(
        id: json['id'] as int,
        name: json['name'] as String,
        strength: json['strength'] as String?,
        unit: json['unit'] as String?,
      );
}

/// One batch's contribution to a voice-order line whose quantity had to be
/// split across batches (FEFO) to be fully satisfied.
class BatchAllocation {
  final int batchId;
  final String? batchNo;
  final String? expiryDate;
  final double qty;
  final double unitPrice;
  final double gstPct;
  final bool expiringSoon;

  BatchAllocation({
    required this.batchId,
    this.batchNo,
    this.expiryDate,
    required this.qty,
    required this.unitPrice,
    required this.gstPct,
    required this.expiringSoon,
  });

  factory BatchAllocation.fromJson(Map<String, dynamic> json) => BatchAllocation(
        batchId: json['batch_id'] as int,
        batchNo: json['batch_no'] as String?,
        expiryDate: (json['expiry_date'] as String?)?.split('T').first,
        qty: (json['qty'] as num).toDouble(),
        unitPrice: (json['unit_price'] as num).toDouble(),
        gstPct: (json['gst_pct'] as num).toDouble(),
        expiringSoon: json['expiring_soon'] as bool? ?? false,
      );
}

/// One parsed line of a voice order — `status` is one of
/// resolved | ambiguous | not_found | no_stock | expired_only.
/// `schedule` is null | "H" | "H1".
class VoiceOrderLine {
  final int id;
  final String rawPhrase;
  final int? productId;
  final String? productName;
  final String? schedule;
  final String? strengthSpoken;
  final double quantity;
  final String? unit;
  final double? baseQuantity;
  final double? unitPrice;
  final double? lineTotal;
  final double? confidence;
  final String status;
  final String? note;
  final List<VoiceLineCandidate> candidates;
  final List<BatchAllocation> batchAllocation;
  final String? resolvedBy;
  final String? prescriptionRef;
  final bool skip;

  VoiceOrderLine({
    required this.id,
    required this.rawPhrase,
    this.productId,
    this.productName,
    this.schedule,
    this.strengthSpoken,
    required this.quantity,
    this.unit,
    this.baseQuantity,
    this.unitPrice,
    this.lineTotal,
    this.confidence,
    required this.status,
    this.note,
    List<VoiceLineCandidate>? candidates,
    List<BatchAllocation>? batchAllocation,
    this.resolvedBy,
    this.prescriptionRef,
    this.skip = false,
  })  : candidates = candidates ?? [],
        batchAllocation = batchAllocation ?? [];

  factory VoiceOrderLine.fromJson(Map<String, dynamic> json) => VoiceOrderLine(
        id: json['id'] as int,
        rawPhrase: json['raw_phrase'] as String? ?? '',
        productId: json['product_id'] as int?,
        productName: json['product_name'] as String?,
        schedule: json['schedule'] as String?,
        strengthSpoken: json['strength_spoken'] as String?,
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String?,
        baseQuantity: (json['base_quantity'] as num?)?.toDouble(),
        unitPrice: (json['unit_price'] as num?)?.toDouble(),
        lineTotal: (json['line_total'] as num?)?.toDouble(),
        confidence: (json['confidence'] as num?)?.toDouble(),
        status: json['status'] as String? ?? 'not_found',
        note: json['note'] as String?,
        candidates: (json['candidates'] as List<dynamic>? ?? [])
            .map((e) => VoiceLineCandidate.fromJson(e as Map<String, dynamic>))
            .toList(),
        batchAllocation: (json['batch_allocation'] as List<dynamic>? ?? [])
            .map((e) => BatchAllocation.fromJson(e as Map<String, dynamic>))
            .toList(),
        resolvedBy: json['resolved_by'] as String?,
        prescriptionRef: json['prescription_ref'] as String?,
        skip: json['skip'] as bool? ?? false,
      );

  bool get isUnresolved => status != 'resolved';
  bool get isSellable => status == 'resolved' && !skip;
}

/// POST /voice-orders/parse, GET /voice-orders/{id}, and the body of every
/// PATCH/line-mutation response — the whole draft, recomputed server-side.
class VoiceOrder {
  final int id;
  final String transcript;
  final String status; // "draft" | "confirmed" | "cancelled"
  final int itemCountHeard;
  final double totalAmount;
  final int? saleId;
  final List<VoiceOrderLine> lines;

  VoiceOrder({
    required this.id,
    required this.transcript,
    required this.status,
    required this.itemCountHeard,
    required this.totalAmount,
    this.saleId,
    required this.lines,
  });

  factory VoiceOrder.fromJson(Map<String, dynamic> json) => VoiceOrder(
        id: json['id'] as int,
        transcript: json['transcript'] as String? ?? '',
        status: json['status'] as String? ?? 'draft',
        itemCountHeard: json['item_count_heard'] as int? ?? 0,
        totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0,
        saleId: json['sale_id'] as int?,
        lines: (json['lines'] as List<dynamic>? ?? [])
            .map((e) => VoiceOrderLine.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Full detail for one saved invoice — GET /invoices/{id}.
class InvoiceDetail {
  final int id;
  final String vendorGstin;
  final String vendorName;
  final String invoiceNo;
  final String invoiceDate;
  final String? invoiceType;
  final String? placeOfSupply;
  final String? sellerDlNo;
  final String? buyerName;
  final String? buyerDlNo;
  final double subtotal;
  final double? totalDiscount;
  final double totalCgst;
  final double totalSgst;
  final double? totalIgst;
  final double? roundOff;
  final double grandTotal;
  final String sourceImagePath;
  // Extra pages of the same continued bill, in order after sourceImagePath
  // — empty for the overwhelming majority of (single-page) invoices.
  final List<String> extraSourceImagePaths;
  final String extractionMethod;
  final double? confidence;
  final bool reviewed;
  final List<ValidationIssue> validationIssues;
  final List<LineItem> lineItems;

  InvoiceDetail({
    required this.id,
    required this.vendorGstin,
    required this.vendorName,
    required this.invoiceNo,
    required this.invoiceDate,
    this.invoiceType,
    this.placeOfSupply,
    this.sellerDlNo,
    this.buyerName,
    this.buyerDlNo,
    required this.subtotal,
    this.totalDiscount,
    required this.totalCgst,
    required this.totalSgst,
    this.totalIgst,
    this.roundOff,
    required this.grandTotal,
    required this.sourceImagePath,
    List<String>? extraSourceImagePaths,
    required this.extractionMethod,
    this.confidence,
    required this.reviewed,
    required this.validationIssues,
    required this.lineItems,
  }) : extraSourceImagePaths = extraSourceImagePaths ?? [];

  factory InvoiceDetail.fromJson(Map<String, dynamic> json) => InvoiceDetail(
        id: json['id'] as int,
        vendorGstin: json['vendor_gstin'] as String,
        vendorName: json['vendor_name'] as String,
        invoiceNo: json['invoice_no'] as String,
        invoiceDate: (json['invoice_date'] as String).split('T').first,
        invoiceType: json['invoice_type'] as String?,
        placeOfSupply: json['place_of_supply'] as String?,
        sellerDlNo: json['seller_dl_no'] as String?,
        buyerName: json['buyer_name'] as String?,
        buyerDlNo: json['buyer_dl_no'] as String?,
        subtotal: (json['subtotal'] as num).toDouble(),
        totalDiscount: (json['total_discount'] as num?)?.toDouble(),
        totalCgst: (json['total_cgst'] as num).toDouble(),
        totalSgst: (json['total_sgst'] as num).toDouble(),
        totalIgst: (json['total_igst'] as num?)?.toDouble(),
        roundOff: (json['round_off'] as num?)?.toDouble(),
        grandTotal: (json['grand_total'] as num).toDouble(),
        sourceImagePath: json['source_image_path'] as String,
        extraSourceImagePaths: (json['extra_source_image_paths'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
        extractionMethod: json['extraction_method'] as String,
        confidence: (json['confidence'] as num?)?.toDouble(),
        reviewed: json['reviewed'] as bool,
        validationIssues: (json['validation_issues'] as List<dynamic>? ?? [])
            .map((e) => ValidationIssue.fromJson(e as Map<String, dynamic>))
            .toList(),
        lineItems: (json['line_items'] as List<dynamic>? ?? [])
            .map((e) => LineItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class AccountInfo {
  final String tenantName;
  final String? gstin;
  final String? address;
  final String email;
  final bool hasGeminiApiKey;
  final String businessType;

  AccountInfo({
    required this.tenantName,
    this.gstin,
    this.address,
    required this.email,
    required this.hasGeminiApiKey,
    required this.businessType,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        tenantName: json['tenant_name'] as String,
        gstin: json['gstin'] as String?,
        address: json['address'] as String?,
        email: json['email'] as String,
        hasGeminiApiKey: json['has_gemini_api_key'] as bool,
        businessType: json['business_type'] as String? ?? 'medical',
      );
}

/// Result of a general voice command (check inventory, delete a sale, add
/// stock, ...) — distinct from [VoiceOrder], which is only ever the
/// multi-item "speak a whole sale" flow. See ApiClient.sendVoiceCommand /
/// confirmVoiceCommand.
class VoiceCommandResult {
  final bool success;
  final String intent;
  final bool requiresConfirmation;
  final String? confirmationToken;
  final String message;
  final Map<String, dynamic>? data;

  VoiceCommandResult({
    required this.success,
    required this.intent,
    required this.requiresConfirmation,
    this.confirmationToken,
    required this.message,
    this.data,
  });

  factory VoiceCommandResult.fromJson(Map<String, dynamic> json) => VoiceCommandResult(
        success: json['success'] as bool? ?? false,
        intent: json['intent'] as String? ?? 'UNKNOWN',
        requiresConfirmation: json['requires_confirmation'] as bool? ?? false,
        confirmationToken: json['confirmation_token'] as String?,
        message: json['message'] as String? ?? '',
        data: json['data'] as Map<String, dynamic>?,
      );
}
