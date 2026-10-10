part of '../../../core/api/api_client.dart';

extension VoiceApi on ApiClient {
  /// Uploads a raw recording for the backend to transcribe (Gemini, not
  /// on-device) and parse — see voice_sale_screen.dart for why this
  /// replaced on-device speech-to-text. [audioFile] is whatever the
  /// `record` package wrote (a .wav file); the filename's extension is what
  /// the backend uses to infer the audio MIME type.
  ///
  /// Returns immediately with a job id — transcription+parsing now run in a
  /// background worker, not inline in this request — so the caller waits on
  /// getVoiceOrderJob(..., wait: true) until it reaches a terminal status.
  Future<int> submitVoiceOrderAudio(File audioFile, {int? voiceOrderId}) async {
    final res = await _multipart(
      '/voice-orders/parse-audio',
      query: voiceOrderId != null ? {'voice_order_id': voiceOrderId.toString()} : null,
      (request) async => request.files
          .add(await http.MultipartFile.fromPath('audio', audioFile.path, contentType: MediaType('audio', 'wav'))),
    );
    return ApiClient._object(res)['job_id'] as int;
  }

  /// With [wait], the server holds the request open until this job changes
  /// state — up to ~25s — instead of answering immediately (DAS-21). One
  /// request per state change rather than one every two seconds. A timeout
  /// or dropped connection here means "ask again", not "the job failed":
  /// every answer re-states current status, so nothing is missed.
  ///
  /// A held request gets [ApiClient.heldTimeout], as [jobStatuses] does: past
  /// the server's hold it is a dead connection, and without a cap a socket
  /// that died silently would leave the caller waiting for ever.
  Future<VoiceOrderJob> getVoiceOrderJob(int jobId, {bool wait = false}) async {
    final res = await _get(
      '/voice-orders/jobs/$jobId',
      query: wait ? {'wait': 'true'} : null,
      timeout: wait ? ApiClient.heldTimeout : ApiClient.readTimeout,
    );
    return VoiceOrderJob.fromJson(ApiClient._object(res));
  }

  Future<VoiceOrder> getVoiceOrder(int id) async =>
      VoiceOrder.fromJson(ApiClient._object(await _get('/voice-orders/$id')));

  /// Patches one line of a draft voice order (product choice, quantity,
  /// unit, prescription ref, or skip) — omit any field left unchanged.
  /// Returns the whole order, recomputed. Throws ApiException(409) if the
  /// order isn't a draft anymore.
  Future<VoiceOrder> updateVoiceOrderLine(
    int orderId,
    int lineId, {
    int? productId,
    double? quantity,
    String? unit,
    String? prescriptionRef,
    bool? skip,
    double? mrp,
    // "percentage" | "amount" — send alongside discountValue when either
    // changes; send discountValue: 0 to clear a discount back to plain MRP.
    String? discountType,
    double? discountValue,
  }) async {
    final res = await _patchJson('/voice-orders/$orderId/lines/$lineId', {
      if (productId != null) 'product_id': productId,
      if (quantity != null) 'quantity': quantity,
      if (unit != null) 'unit': unit,
      if (prescriptionRef != null) 'prescription_ref': prescriptionRef,
      if (skip != null) 'skip': skip,
      if (mrp != null) 'mrp': mrp,
      if (discountType != null) 'discount_type': discountType,
      if (discountValue != null) 'discount_value': discountValue,
    });
    return VoiceOrder.fromJson(ApiClient._object(res));
  }

  Future<VoiceOrder> addVoiceOrderLine(
    int orderId, {
    required int productId,
    required double quantity,
    required String unit,
    double? mrp,
    String? discountType,
    double? discountValue,
  }) async {
    final res = await _postJson('/voice-orders/$orderId/lines', {
      'product_id': productId,
      'quantity': quantity,
      'unit': unit,
      if (mrp != null) 'mrp': mrp,
      if (discountType != null) 'discount_type': discountType,
      if (discountValue != null) 'discount_value': discountValue,
    });
    return VoiceOrder.fromJson(ApiClient._object(res));
  }

  Future<Map<String, dynamic>> confirmVoiceOrder(
    int orderId, {
    String? buyerName,
    String? buyerGstin,
  }) async {
    final res = await _postJson(
        '/voice-orders/$orderId/confirm',
        {
          'buyer_name': (buyerName == null || buyerName.isEmpty) ? null : buyerName,
          'buyer_gstin': (buyerGstin == null || buyerGstin.isEmpty) ? null : buyerGstin,
        },
        timeout: ApiClient.workTimeout);
    return ApiClient._object(res);
  }

  Future<void> cancelVoiceOrder(int orderId) => _post('/voice-orders/$orderId/cancel');

  Future<void> undoVoiceOrder(int orderId) => _post('/voice-orders/$orderId/undo');

  /// General voice command (check inventory, delete a sale, add stock,
  /// ...) — distinct from the voice-sale flow above. The backend never
  /// executes a destructive action from this call alone: a
  /// [VoiceCommandResult.requiresConfirmation] response must be followed by
  /// [confirmVoiceCommand] with its [VoiceCommandResult.confirmationToken]
  /// before anything is actually deleted/removed.
  ///
  /// Answered only once the recording has been transcribed and understood,
  /// so it gets the transfer timeout, not a read's.
  Future<VoiceCommandResult> sendVoiceCommand(File audioFile) async {
    final res = await _multipart(
      '/voice-commands/audio',
      (request) async => request.files
          .add(await http.MultipartFile.fromPath('audio', audioFile.path, contentType: MediaType('audio', 'wav'))),
    );
    return VoiceCommandResult.fromJson(ApiClient._object(res));
  }

  Future<VoiceCommandResult> confirmVoiceCommand(String confirmationToken) async {
    final res = await _postJson('/voice-commands/confirm', {'confirmation_token': confirmationToken});
    return VoiceCommandResult.fromJson(ApiClient._object(res));
  }
}
