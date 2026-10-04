library;

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
        id: json['id'] as int,
        rawPhrase: json['raw_phrase'] as String? ?? '',
        productId: json['product_id'] as int?,
        productName: json['product_name'] as String?,
        schedule: json['schedule'] as String?,
        strengthSpoken: json['strength_spoken'] as String?,
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String?,
        baseQuantity: (json['base_quantity'] as num?)?.toDouble(),
        mrp: (json['mrp'] as num?)?.toDouble(),
        discountType: json['discount_type'] as String?,
        discountValue: (json['discount_value'] as num?)?.toDouble(),
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

  /// A worker has this job in hand, so the per-attempt clock should run.
  /// 'queued' is deliberately excluded: waiting behind someone else's
  /// recording is not the job taking too long. See poll.dart's isStarted.
  bool get isBeingWorkedOn => status == 'transcribing' || status == 'parsing';

  factory VoiceOrderJob.fromJson(Map<String, dynamic> json) {
    final error = json['error'] as Map<String, dynamic>?;
    return VoiceOrderJob(
      jobId: json['job_id'] as int,
      status: json['status'] as String,
      order: json['order'] != null ? VoiceOrder.fromJson(json['order'] as Map<String, dynamic>) : null,
      errorKind: error?['kind'] as String?,
      errorMessage: error?['message'] as String?,
      attempt: json['attempt'] as int? ?? 0,
      maxAttempts: json['max_attempts'] as int? ?? 3,
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
        success: json['success'] as bool? ?? false,
        intent: json['intent'] as String? ?? 'UNKNOWN',
        requiresConfirmation: json['requires_confirmation'] as bool? ?? false,
        confirmationToken: json['confirmation_token'] as String?,
        message: json['message'] as String? ?? '',
        data: json['data'] as Map<String, dynamic>?,
      );
}
