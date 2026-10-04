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
    final query = voiceOrderId != null ? {'voice_order_id': voiceOrderId.toString()} : null;
    final request = http.MultipartRequest('POST', _uri('/voice-orders/parse-audio', query))
      ..headers.addAll(_authHeader)
      ..files.add(await http.MultipartFile.fromPath('audio', audioFile.path, contentType: MediaType('audio', 'wav')));
    final streamed = await request.send();
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['job_id'] as int;
  }

  /// With [wait], the server holds the request open until this job changes
  /// state — up to ~25s — instead of answering immediately (DAS-21). One
  /// request per state change rather than one every two seconds. A timeout
  /// or dropped connection here means "ask again", not "the job failed":
  /// every answer re-states current status, so nothing is missed.
  Future<VoiceOrderJob> getVoiceOrderJob(int jobId, {bool wait = false}) async {
    final res = await http.get(
      _uri('/voice-orders/jobs/$jobId', wait ? {'wait': 'true'} : null),
      headers: _authHeader,
    );
    _checkOk(res);
    return VoiceOrderJob.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<VoiceOrder> getVoiceOrder(int id) async {
    final res = await http.get(_uri('/voice-orders/$id'), headers: _authHeader);
    _checkOk(res);
    return VoiceOrder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

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
    final body = <String, dynamic>{};
    if (productId != null) body['product_id'] = productId;
    if (quantity != null) body['quantity'] = quantity;
    if (unit != null) body['unit'] = unit;
    if (prescriptionRef != null) body['prescription_ref'] = prescriptionRef;
    if (skip != null) body['skip'] = skip;
    if (mrp != null) body['mrp'] = mrp;
    if (discountType != null) body['discount_type'] = discountType;
    if (discountValue != null) body['discount_value'] = discountValue;
    final res = await http.patch(
      _uri('/voice-orders/$orderId/lines/$lineId'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    return VoiceOrder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
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
    final body = <String, dynamic>{
      'product_id': productId,
      'quantity': quantity,
      'unit': unit,
    };
    if (mrp != null) body['mrp'] = mrp;
    if (discountType != null) body['discount_type'] = discountType;
    if (discountValue != null) body['discount_value'] = discountValue;
    final res = await http.post(
      _uri('/voice-orders/$orderId/lines'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    return VoiceOrder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> confirmVoiceOrder(
    int orderId, {
    String? buyerName,
    String? buyerGstin,
  }) async {
    final res = await http.post(
      _uri('/voice-orders/$orderId/confirm'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'buyer_name': (buyerName == null || buyerName.isEmpty) ? null : buyerName,
        'buyer_gstin': (buyerGstin == null || buyerGstin.isEmpty) ? null : buyerGstin,
      }),
    );
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> cancelVoiceOrder(int orderId) async {
    final res = await http.post(_uri('/voice-orders/$orderId/cancel'), headers: _authHeader);
    _checkOk(res);
  }

  Future<void> undoVoiceOrder(int orderId) async {
    final res = await http.post(_uri('/voice-orders/$orderId/undo'), headers: _authHeader);
    _checkOk(res);
  }

  /// General voice command (check inventory, delete a sale, add stock,
  /// ...) — distinct from the voice-sale flow above. The backend never
  /// executes a destructive action from this call alone: a
  /// [VoiceCommandResult.requiresConfirmation] response must be followed by
  /// [confirmVoiceCommand] with its [VoiceCommandResult.confirmationToken]
  /// before anything is actually deleted/removed.
  Future<VoiceCommandResult> sendVoiceCommand(File audioFile) async {
    final request = http.MultipartRequest('POST', _uri('/voice-commands/audio'))
      ..headers.addAll(_authHeader)
      ..files.add(await http.MultipartFile.fromPath('audio', audioFile.path, contentType: MediaType('audio', 'wav')));
    final streamed = await request.send();
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return VoiceCommandResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<VoiceCommandResult> confirmVoiceCommand(String confirmationToken) async {
    final res = await http.post(
      _uri('/voice-commands/confirm'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'confirmation_token': confirmationToken}),
    );
    _checkOk(res);
    return VoiceCommandResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }
}
