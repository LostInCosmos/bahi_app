/// Data models mirroring backend/app/schemas.py — kept in lockstep with the
/// invoice JSON schema so the review form can round-trip an extraction
/// result straight into a save request.
library;

import '../../../core/utils/json.dart';

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
  // The single printed Disc/Discount value. The server decides whether it is a
  // % or a rupee amount and returns its answer in discountPct/discountAmount.
  // Kept and echoed back so revalidate still has the printed figure after the
  // derived ones are cleared (DAS-9).
  double? discount;
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
  // Renamed from lineAmount (backend: line_amount -> gross_amount) — the
  // row's main printed pre-tax amount, still required. A netAmount
  // (after-discount-and-tax total) field was tried and removed — extraction
  // couldn't reliably tell it apart from a per-unit "Net Rate" column, so
  // gross_amount is the only per-line amount now.
  double grossAmount;
  // The rate after the line's discount, per unit. Worked out by the server
  // (and sometimes printed); never shown here, carried back so a save or
  // revalidate sends what the server sent (DAS-136).
  double? netRate;

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
    this.discount,
    this.discountPct,
    this.discountAmount,
    this.gstPct = 0,
    this.cgstPct,
    this.sgstPct,
    this.igstPct,
    this.cgstAmount,
    this.sgstAmount,
    this.igstAmount,
    this.grossAmount = 0,
    this.netRate,
  });

  factory LineItem.fromJson(Map<String, dynamic> json) => LineItem(
        productName: json.strOr('product_name'),
        pack: json.str('pack'),
        batchNo: json.str('batch_no'),
        expiry: json.str('expiry'),
        hsnCode: json.str('hsn_code'),
        qty: json.dblOr('qty'),
        freeQty: json.dbl('free_qty'),
        freeScheme: json.str('free_scheme'),
        mrp: json.dbl('mrp'),
        rate: json.dblOr('rate'),
        discount: json.dbl('discount'),
        discountPct: json.dbl('discount_pct'),
        discountAmount: json.dbl('discount_amount'),
        gstPct: json.dblOr('gst_pct'),
        cgstPct: json.dbl('cgst_pct'),
        sgstPct: json.dbl('sgst_pct'),
        igstPct: json.dbl('igst_pct'),
        cgstAmount: json.dbl('cgst_amount'),
        sgstAmount: json.dbl('sgst_amount'),
        igstAmount: json.dbl('igst_amount'),
        grossAmount: json.dblOr('gross_amount'),
        netRate: json.dbl('net_rate'),
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
        'discount': discount,
        'discount_pct': discountPct,
        'discount_amount': discountAmount,
        'gst_pct': gstPct,
        'cgst_pct': cgstPct,
        'sgst_pct': sgstPct,
        'igst_pct': igstPct,
        'cgst_amount': cgstAmount,
        'sgst_amount': sgstAmount,
        'igst_amount': igstAmount,
        'gross_amount': grossAmount,
        'net_rate': netRate,
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
  // A second printed discount line, and the printed total GST. Not shown on
  // the review form; carried back so a save or revalidate keeps them
  // (DAS-136). The server's totals check adds total_discount_2 to
  // total_discount: dropping it flagged a correct bill.
  double? totalDiscount2;
  double? totalGst;

  Totals({
    this.subtotal = 0,
    this.totalDiscount,
    this.totalCgst = 0,
    this.totalSgst = 0,
    this.totalIgst,
    this.roundOff,
    this.grandTotal = 0,
    this.totalDiscount2,
    this.totalGst,
  });

  factory Totals.fromJson(Map<String, dynamic> json) => Totals(
        subtotal: json.dblOr('subtotal'),
        totalDiscount: json.dbl('total_discount'),
        totalCgst: json.dblOr('total_cgst'),
        totalSgst: json.dblOr('total_sgst'),
        totalIgst: json.dbl('total_igst'),
        roundOff: json.dbl('round_off'),
        grandTotal: json.dblOr('grand_total'),
        totalDiscount2: json.dbl('total_discount_2'),
        totalGst: json.dbl('total_gst'),
      );

  Map<String, dynamic> toJson() => {
        'subtotal': subtotal,
        'total_discount': totalDiscount,
        'total_cgst': totalCgst,
        'total_sgst': totalSgst,
        'total_igst': totalIgst,
        'round_off': roundOff,
        'grand_total': grandTotal,
        'total_discount_2': totalDiscount2,
        'total_gst': totalGst,
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
        sellerName: json.strOr('seller_name'),
        sellerGstin: json.strOr('seller_gstin'),
        sellerAddress: json.str('seller_address'),
        sellerPhone: json.str('seller_phone'),
        sellerDlNo: json.str('seller_dl_no'),
        buyerName: json.str('buyer_name'),
        buyerDlNo: json.str('buyer_dl_no'),
        invoiceNo: json.strOr('invoice_no'),
        invoiceDate: json.strOr('invoice_date'),
        invoiceType: json.str('invoice_type'),
        placeOfSupply: json.str('place_of_supply'),
        lineItems: json.listOf('line_items', LineItem.fromJson),
        totals: Totals.fromJson(json.obj('totals') ?? {}),
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
  // Bumped by the server each time the admin rotates this bill's photo in
  // place (DAS-72) — the object at [sourceImage] is overwritten under the
  // same name, so this is what tells a client caching by path to refetch.
  // See ApiClient.fetchImage / BillImageCache. The server sends it on the job,
  // not inside extraction_meta: ExtractionJob.fromJson sets it here (DAS-150;
  // read from the meta it was always 0, so a rotated photo stayed stale).
  int imageRev;

  /// The read this meta belongs to (DAS-153), echoed on a save so the server
  /// saves against that read and clears its draft. Null from a server that
  /// does not send it; the server then finds the read by [sourceImage].
  int? jobId;

  ExtractionMeta({
    required this.sourceImage,
    List<String>? extraSourceImages,
    required this.method,
    this.templateId,
    this.confidence,
    this.reviewedByUser = false,
    this.vendorKnown = false,
    this.imageRev = 0,
    this.jobId,
  }) : extraSourceImages = extraSourceImages ?? [];

  factory ExtractionMeta.fromJson(Map<String, dynamic> json) => ExtractionMeta(
        sourceImage: json.strOr('source_image'),
        extraSourceImages: json.strList('extra_source_images'),
        method: json.strOr('method', 'llm'),
        templateId: json.integer('template_id'),
        confidence: json.dbl('confidence'),
        reviewedByUser: json.boolOr('reviewed_by_user'),
        vendorKnown: json.boolOr('vendor_known'),
        jobId: json.integer('job_id'),
      );

  /// What a save sends: this read's meta, marked as checked by a person.
  /// Everything else is echoed back as the server sent it. [pages], when
  /// given, replaces the page list — see the capture screen's one-tap save.
  ExtractionMeta reviewed({List<String>? pages}) => ExtractionMeta(
        sourceImage: pages == null || pages.isEmpty ? sourceImage : pages.first,
        extraSourceImages: pages == null || pages.isEmpty ? extraSourceImages : pages.skip(1).toList(),
        method: method,
        templateId: templateId,
        confidence: confidence,
        reviewedByUser: true,
        vendorKnown: vendorKnown,
        imageRev: imageRev,
        jobId: jobId,
      );

  Map<String, dynamic> toJson() => {
        'source_image': sourceImage,
        'extra_source_images': extraSourceImages,
        'method': method,
        'template_id': templateId,
        'confidence': confidence,
        'reviewed_by_user': reviewedByUser,
        'vendor_known': vendorKnown,
        if (jobId != null) 'job_id': jobId,
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
        field: json.strReq('field'),
        severity: json.strReq('severity'),
        message: json.strReq('message'),
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
        issues: json.listOf('issues', ValidationIssue.fromJson),
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
        issues: json.listOf('issues', ValidationIssue.fromJson),
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
  ///
  /// [extraSourceImages] keeps a multi-page bill's other pages, which the
  /// form saves with it.
  factory ExtractionResult.blank(String sourceImage, String message, {List<String>? extraSourceImages}) =>
      ExtractionResult(
        invoice: InvoiceData(),
        meta: ExtractionMeta(
          sourceImage: sourceImage,
          extraSourceImages: extraSourceImages,
          method: 'llm',
          reviewedByUser: false,
        ),
        issues: [ValidationIssue(field: 'invoice', severity: 'warning', message: message)],
      );
}

/// The shop's unsaved corrections to a read bill, kept on the server so they
/// survive the phone's card going and reach every phone of the shop
/// (DAS-153). Written by `PUT /invoices/extract/{job}/draft`, which validates
/// like `/invoices/revalidate`; [issues] are as of that write.
class BillDraft {
  final InvoiceData invoice;
  final List<ValidationIssue> issues;

  /// Null only for corrections this phone holds that never reached the
  /// server.
  final int? rev;
  final DateTime? savedAt;

  /// The read changed after this was written (our team corrected or re-read
  /// the bill). Kept, never dropped; saving it is refused until the shop
  /// chooses to keep it (`rebase`) or takes the team's version.
  final bool stale;

  const BillDraft({required this.invoice, required this.issues, this.rev, this.savedAt, this.stale = false});

  factory BillDraft.fromJson(Map<String, dynamic> json) => BillDraft(
        invoice: InvoiceData.fromJson(json['invoice'] as Map<String, dynamic>),
        issues: json.listOf('issues', ValidationIssue.fromJson),
        rev: json.intReq('draft_rev'),
        savedAt: json.utcLenient('draft_saved_at'),
        stale: json.boolOr('stale'),
      );
}

/// What a draft write answers: the same as a revalidate, plus the draft's
/// new revision.
class DraftReply {
  final RevalidateResult result;
  final int rev;
  final bool stale;

  const DraftReply(this.result, {required this.rev, this.stale = false});

  factory DraftReply.fromJson(Map<String, dynamic> json) =>
      DraftReply(RevalidateResult.fromJson(json), rev: json.intReq('draft_rev'), stale: json.boolOr('stale'));
}

/// GET /invoices/extract/{jobId} — extraction runs in a background worker,
/// so the client submits a job (see ApiClient.submitExtraction) and polls
/// this until [isTerminal].
class ExtractionJob {
  final int jobId;
  /// 'queued' | 'processing' | 'retrying' | 'done' | 'failed' | 'cancelled'
  /// ('pending' may still arrive from a server mid-deploy.)
  final String status;
  final ExtractionResult? result; // set iff status == 'done'
  final String? errorKind; // e.g. 'structural_validation_failed', 'attempts_exhausted' — set iff status == 'failed'
  final String? errorMessage;
  final String? sourceImage;
  final List<String>? extraSourceImages;
  /// Worker attempts so far, out of [maxAttempts]. A failed read is retried
  /// automatically with a growing delay before it is given up on.
  final int attempt;
  final int maxAttempts;
  /// When a `retrying` job will next be picked up. UTC.
  final DateTime? retryAt;
  /// Set once the server has saved this job's bill — on the first read that
  /// came back clean, or later, server-side, once an admin correction
  /// clears the last issue (DAS-79). Null until then, including while a
  /// clean bill's own save attempt has failed (a duplicate invoice number,
  /// a FEFO surprise) — that bill stays unsaved until a human saves it or
  /// an admin's retried read succeeds. Same meaning as the upload-list rows
  /// already carried.
  final int? invoiceId;
  final String? reviewState;

  /// The shop's unsaved corrections, if any (DAS-153). [result] stays the
  /// read — the machine's or our team's — so the original is never lost.
  final BillDraft? draft;

  ExtractionJob({
    required this.jobId,
    required this.status,
    this.result,
    this.errorKind,
    this.errorMessage,
    this.sourceImage,
    this.extraSourceImages,
    this.attempt = 0,
    this.maxAttempts = 3,
    this.retryAt,
    this.invoiceId,
    this.reviewState,
    this.draft,
  });

  /// `cancelled` belongs here too: without it a cancelled job was not
  /// terminal, so the app polled it for ever. Written as the set of finished
  /// states rather than the set of unfinished ones, so a status the server
  /// adds later keeps the app polling instead of falsely calling it done.
  bool get isTerminal => status == 'done' || status == 'failed' || status == 'cancelled';

  bool get isRetrying => status == 'retrying';

  /// The server already saved this bill by the time we asked — no tap
  /// needed (DAS-79). Checked before falling back to the pendingConfirm /
  /// needsReview split, which only applies to what is still unsaved.
  bool get isAlreadySaved => invoiceId != null;

  factory ExtractionJob.fromJson(Map<String, dynamic> json) {
    final error = json.obj('error');
    return ExtractionJob(
      jobId: json.intReq('job_id'),
      status: json.strReq('status'),
      result: json.objOf('result', ExtractionResult.fromJson)?..meta.imageRev = json.intOr('image_rev'),
      errorKind: error?.str('kind'),
      errorMessage: error?.str('message'),
      sourceImage: error?.str('source_image'),
      // Null when the server sent none, so the caller falls back to the pages
      // it already knows; an empty list would mean "there are no more".
      extraSourceImages: (error?['extra_source_images'] as List?)?.cast<String>(),
      attempt: json.intOr('attempt', 0),
      maxAttempts: json.intOr('max_attempts', 3),
      retryAt: json.utcLenient('retry_at'),
      invoiceId: json.integer('invoice_id'),
      reviewState: json.str('review_state'),
      draft: json.objOf('draft', BillDraft.fromJson),
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
  final int? folderId;

  InvoiceSummary({
    required this.id,
    required this.vendorGstin,
    required this.vendorName,
    required this.invoiceNo,
    required this.invoiceDate,
    required this.grandTotal,
    required this.reviewed,
    required this.extractionMethod,
    this.folderId,
  });

  factory InvoiceSummary.fromJson(Map<String, dynamic> json) => InvoiceSummary(
        id: json.intReq('id'),
        vendorGstin: json.strReq('vendor_gstin'),
        vendorName: json.strReq('vendor_name'),
        invoiceNo: json.strReq('invoice_no'),
        invoiceDate: json.dateOnlyReq('invoice_date'),
        grandTotal: json.dblReq('grand_total'),
        reviewed: json.boolReq('reviewed'),
        extractionMethod: json.strReq('extraction_method'),
        folderId: json.integer('folder_id'),
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

  /// `none` | `pending` | `done` (DAS-71); null on a server that predates it.
  final String? reviewState;

  /// Bumped when the admin rotates this bill's photo in place (DAS-72); 0 on
  /// a server that predates the field. Applies to every path above — the
  /// admin rotates one page of a bill at a time, but the server has only one
  /// counter per invoice. See ExtractionMeta.imageRev.
  final int imageRev;

  /// Our team still has to look at this bill (see [UploadSummary.isUnderReview]).
  bool get isUnderReview => reviewState != null && reviewState != 'none' && reviewState != 'done';

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
    this.reviewState,
    this.imageRev = 0,
  }) : extraSourceImagePaths = extraSourceImagePaths ?? [];

  factory InvoiceDetail.fromJson(Map<String, dynamic> json) => InvoiceDetail(
        id: json.intReq('id'),
        vendorGstin: json.strReq('vendor_gstin'),
        vendorName: json.strReq('vendor_name'),
        invoiceNo: json.strReq('invoice_no'),
        invoiceDate: json.dateOnlyReq('invoice_date'),
        invoiceType: json.str('invoice_type'),
        placeOfSupply: json.str('place_of_supply'),
        sellerDlNo: json.str('seller_dl_no'),
        buyerName: json.str('buyer_name'),
        buyerDlNo: json.str('buyer_dl_no'),
        subtotal: json.dblReq('subtotal'),
        totalDiscount: json.dbl('total_discount'),
        totalCgst: json.dblReq('total_cgst'),
        totalSgst: json.dblReq('total_sgst'),
        totalIgst: json.dbl('total_igst'),
        roundOff: json.dbl('round_off'),
        grandTotal: json.dblReq('grand_total'),
        sourceImagePath: json.strReq('source_image_path'),
        extraSourceImagePaths: json.strList('extra_source_image_paths'),
        extractionMethod: json.strReq('extraction_method'),
        confidence: json.dbl('confidence'),
        reviewed: json.boolReq('reviewed'),
        validationIssues: json.listOf('validation_issues', ValidationIssue.fromJson),
        lineItems: json.listOf('line_items', LineItem.fromJson),
        reviewState: json.str('review_state'),
        imageRev: json.intOr('image_rev'),
      );
}

/// The answer to saving a bill by job (`POST /invoices/extract/{id}/save`).
class SavedJob {
  final int invoiceId;

  /// `none` | `pending` | `done` for the bill just saved; null on a server
  /// that does not say.
  final String? reviewState;

  const SavedJob({required this.invoiceId, this.reviewState});
}
