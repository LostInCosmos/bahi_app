library;

import '../../../core/utils/json.dart';

/// One candidate product offered for an ambiguous/not_found voice-order
/// line — shown in a bottom sheet so the shopkeeper taps the right one.
class VoiceLineCandidate {
  final int id;
  final String name;
  final String? strength;
  final String? unit;

  VoiceLineCandidate({required this.id, required this.name, this.strength, this.unit});

  factory VoiceLineCandidate.fromJson(Map<String, dynamic> json) => VoiceLineCandidate(
        id: json.intReq('id'),
        name: json.strReq('name'),
        strength: json.str('strength'),
        unit: json.str('unit'),
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
        batchId: json.intReq('batch_id'),
        batchNo: json.str('batch_no'),
        expiryDate: json.dateOnly('expiry_date'),
        qty: json.dblReq('qty'),
        unitPrice: json.dblReq('unit_price'),
        gstPct: json.dblReq('gst_pct'),
        expiringSoon: json.boolOr('expiring_soon'),
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
  final double? mrp;
  final String? discountType; // "percentage" | "amount"
  final double? discountValue;
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
    this.mrp,
    this.discountType,
    this.discountValue,
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
        id: json.intReq('id'),
        rawPhrase: json.strOr('raw_phrase'),
        productId: json.integer('product_id'),
        productName: json.str('product_name'),
        schedule: json.str('schedule'),
        strengthSpoken: json.str('strength_spoken'),
        quantity: json.dblOr('quantity'),
        unit: json.str('unit'),
        baseQuantity: json.dbl('base_quantity'),
        mrp: json.dbl('mrp'),
        discountType: json.str('discount_type'),
        discountValue: json.dbl('discount_value'),
        unitPrice: json.dbl('unit_price'),
        lineTotal: json.dbl('line_total'),
        confidence: json.dbl('confidence'),
        status: json.strOr('status', 'not_found'),
        note: json.str('note'),
        candidates: json.listOf('candidates', VoiceLineCandidate.fromJson),
        batchAllocation: json.listOf('batch_allocation', BatchAllocation.fromJson),
        resolvedBy: json.str('resolved_by'),
        prescriptionRef: json.str('prescription_ref'),
        skip: json.boolOr('skip'),
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
        id: json.intReq('id'),
        transcript: json.strOr('transcript'),
        status: json.strOr('status', 'draft'),
        itemCountHeard: json.intOr('item_count_heard', 0),
        totalAmount: json.dblOr('total_amount'),
        saleId: json.integer('sale_id'),
        lines: json.listOf('lines', VoiceOrderLine.fromJson),
      );
}

/// GET /voice-orders/jobs/{jobId} — voice-order parsing now runs in a
/// background worker instead of inline during POST /voice-orders/parse-audio
/// (same shape as ExtractionJob for bills), so the client submits a job
/// (see ApiClient.submitVoiceOrderAudio) and polls this until status is no
/// longer 'pending'/'transcribing'/'parsing'.
class VoiceOrderJob {
  final int jobId;
  /// 'queued' | 'transcribing' | 'parsing' | 'retrying' | 'done' | 'failed' | 'cancelled'
  final String status;
  final VoiceOrder? order; // set iff status == 'done'
  final String? errorKind; // 'structural_parse_failed' | 'no_speech' | 'attempts_exhausted' | 'generic'
  final String? errorMessage;
  final int attempt;
  final int maxAttempts;

  VoiceOrderJob({
    required this.jobId,
    required this.status,
    this.order,
    this.errorKind,
    this.errorMessage,
    this.attempt = 0,
    this.maxAttempts = 3,
  });

  /// See ExtractionJob.isTerminal — `cancelled` was missing, so a cancelled
  /// job was polled for ever. Listed as finished states, so an unknown new
  /// status keeps polling rather than being mistaken for done.
  bool get isTerminal => status == 'done' || status == 'failed' || status == 'cancelled';

  bool get isRetrying => status == 'retrying';

  factory VoiceOrderJob.fromJson(Map<String, dynamic> json) {
    final error = json.obj('error');
    return VoiceOrderJob(
      jobId: json.intReq('job_id'),
      status: json.strReq('status'),
      order: json.objOf('order', VoiceOrder.fromJson),
      errorKind: error?.str('kind'),
      errorMessage: error?.str('message'),
      attempt: json.intOr('attempt', 0),
      maxAttempts: json.intOr('max_attempts', 3),
    );
  }
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
        success: json.boolOr('success'),
        intent: json.strOr('intent', 'UNKNOWN'),
        requiresConfirmation: json.boolOr('requires_confirmation'),
        confirmationToken: json.str('confirmation_token'),
        message: json.strOr('message'),
        data: json.obj('data'),
      );
}
