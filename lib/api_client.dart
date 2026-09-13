import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  /// The raw `detail` field from the response body, when the body was JSON
  /// with a structured detail (a String, or a Map like
  /// `{"error": "validation_failed", "issues": [...]}`). Callers that need
  /// to branch on the specific error kind (validation vs. structural
  /// extraction failure) should inspect this instead of parsing [message].
  final dynamic detail;

  ApiException(this.statusCode, this.message, [this.detail]);

  @override
  String toString() => message;
}

/// Thin REST client for the FastAPI backend. Holds the base URL and JWT in
/// memory plus SharedPreferences so both survive app restarts. The base URL
/// is user-editable from the login screen since "localhost" means different
/// things on an emulator (10.0.2.2), a physical device (the host's LAN IP),
/// and a desktop build.
class ApiClient {
  ApiClient._internal();
  static final ApiClient instance = ApiClient._internal();

  String baseUrl = "http://10.0.2.2:8000";
  String? token;

  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('base_url') ?? baseUrl;
    token = prefs.getString('token');
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base_url', url);
  }

  Future<void> _saveToken(String token) async {
    this.token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
  }

  Future<void> logout() async {
    token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }

  bool get isLoggedIn => token != null;

  Map<String, String> get _authHeader => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  void _checkOk(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String message = res.body;
    dynamic detail;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'];
        message = detail is String ? detail : jsonEncode(detail);
      }
    } catch (_) {
      // response wasn't JSON — fall back to raw body
    }
    throw ApiException(res.statusCode, message, detail);
  }

  Future<void> signup({
    required String tenantName,
    required String email,
    required String password,
    String? geminiApiKey,
    String? businessType,
  }) async {
    final res = await http.post(
      _uri('/auth/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'tenant_name': tenantName,
        'email': email,
        'password': password,
        'gemini_api_key': geminiApiKey,
        'business_type': businessType,
      }),
    );
    _checkOk(res);
    await _saveToken(jsonDecode(res.body)['access_token'] as String);
  }

  Future<void> login({required String email, required String password}) async {
    final res = await http.post(
      _uri('/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    _checkOk(res);
    await _saveToken(jsonDecode(res.body)['access_token'] as String);
  }

  Future<AccountInfo> getAccount() async {
    final res = await http.get(_uri('/account'), headers: _authHeader);
    _checkOk(res);
    return AccountInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Omit any field left unchanged. [geminiApiKey] as an empty string clears
  /// it (falls back to the pooled server key); omit it entirely to leave
  /// whatever's already set untouched — same convention as the web app.
  Future<AccountInfo> updateAccount({
    String? tenantName,
    String? gstin,
    String? address,
    String? businessType,
    String? geminiApiKey,
  }) async {
    final body = <String, dynamic>{};
    if (tenantName != null) body['tenant_name'] = tenantName;
    if (gstin != null) body['gstin'] = gstin;
    if (address != null) body['address'] = address;
    if (businessType != null) body['business_type'] = businessType;
    if (geminiApiKey != null) body['gemini_api_key'] = geminiApiKey;
    final res = await http.patch(
      _uri('/account'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    return AccountInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Uploads the raw photo plus the four corners the user dragged onto the
  /// bill (in the *original* image's pixel space) and a post-warp rotation.
  /// Returns the relative path of the corrected image on the server.
  Future<String> preprocess({
    required Uint8List imageBytes,
    required String filename,
    required List<Offset2D> corners,
    required int rotationDegrees,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/invoices/preprocess'))
      ..headers.addAll(_authHeader)
      ..fields['corners'] = jsonEncode(corners.map((c) => {'x': c.x, 'y': c.y}).toList())
      ..fields['rotation_degrees'] = rotationDegrees.toString()
      ..files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: filename));

    final streamed = await request.send();
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return jsonDecode(res.body)['source_image'] as String;
  }

  Future<Uint8List> fetchImage(String sourceImage) async {
    final res = await http.get(_uri('/invoices/image/$sourceImage'), headers: _authHeader);
    _checkOk(res);
    return res.bodyBytes;
  }

  /// [extraSourceImages] are additional pages of the SAME bill (see
  /// CaptureScreen's multi-page capture) — sent as repeated form fields
  /// (not a Map, which can't hold duplicate keys) so the backend receives
  /// them as a real list and stitches every page into one Gemini call.
  Future<ExtractionResult> extract(String sourceImage, {List<String> extraSourceImages = const []}) async {
    final request = http.MultipartRequest('POST', _uri('/invoices/extract'))
      ..headers.addAll(_authHeader)
      ..fields['source_image'] = sourceImage;
    for (final img in extraSourceImages) {
      request.files.add(http.MultipartFile.fromString('extra_source_images', img));
    }
    final streamed = await request.send();
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return ExtractionResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<RevalidateResult> revalidateInvoice(InvoiceData invoice) async {
    final res = await http.post(
      _uri('/invoices/revalidate'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(invoice.toJson()),
    );
    _checkOk(res);
    return RevalidateResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<int> saveInvoice(InvoiceData invoice, ExtractionMeta meta, {bool overrideErrors = false}) async {
    final res = await http.post(
      _uri('/invoices'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'invoice': invoice.toJson(),
        'extraction_meta': meta.toJson(),
        'override_errors': overrideErrors,
      }),
    );
    _checkOk(res);
    return jsonDecode(res.body)['invoice_id'] as int;
  }

  Future<List<InvoiceSummary>> listInvoices({
    String? startDate,
    String? endDate,
    String? vendorGstin,
  }) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    if (vendorGstin != null && vendorGstin.isNotEmpty) query['vendor_gstin'] = vendorGstin;

    final res = await http.get(_uri('/invoices', query), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => InvoiceSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<InvoiceDetail> getInvoiceDetail(int invoiceId) async {
    final res = await http.get(_uri('/invoices/$invoiceId'), headers: _authHeader);
    _checkOk(res);
    return InvoiceDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Reverses the stock this invoice added to inventory, then removes it.
  /// Throws ApiException(409) if some of that stock has already been sold —
  /// the caller should surface `.message` rather than retry.
  Future<void> deleteInvoice(int invoiceId) async {
    final res = await http.delete(_uri('/invoices/$invoiceId'), headers: _authHeader);
    _checkOk(res);
  }

  Future<Uint8List> exportExcel({
    String? startDate,
    String? endDate,
    String? vendorGstin,
  }) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    if (vendorGstin != null && vendorGstin.isNotEmpty) query['vendor_gstin'] = vendorGstin;

    final res = await http.get(_uri('/export/excel', query), headers: _authHeader);
    _checkOk(res);
    return res.bodyBytes;
  }

  Future<List<ProductSummary>> searchProducts({String? q}) async {
    final query = <String, String>{};
    if (q != null && q.isNotEmpty) query['q'] = q;
    final res = await http.get(_uri('/inventory/products', query), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => ProductSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProductDetail> getProductDetail(int productId) async {
    final res = await http.get(_uri('/inventory/products/$productId'), headers: _authHeader);
    _checkOk(res);
    return ProductDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> createSale({
    String? buyerName,
    String? buyerGstin,
    required List<CartEntry> lineItems,
  }) async {
    final res = await http.post(
      _uri('/sales'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'buyer_name': (buyerName == null || buyerName.isEmpty) ? null : buyerName,
        'buyer_gstin': (buyerGstin == null || buyerGstin.isEmpty) ? null : buyerGstin,
        'line_items': lineItems
            .map((c) => {'product_batch_id': c.productBatchId, 'qty': c.qty, 'rate': c.rate})
            .toList(),
      }),
    );
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<SaleDetail> getSaleDetail(int saleId) async {
    final res = await http.get(_uri('/sales/$saleId'), headers: _authHeader);
    _checkOk(res);
    return SaleDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<SaleSummary>> listSales({String? startDate, String? endDate}) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    final res = await http.get(_uri('/sales', query), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => SaleSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Uint8List> exportSalesExcel({String? startDate, String? endDate}) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    final res = await http.get(_uri('/export/sales-excel', query), headers: _authHeader);
    _checkOk(res);
    return res.bodyBytes;
  }

  /// Sends a spoken sale (already transcribed on-device) to be parsed into a
  /// priced draft. Pass [voiceOrderId] to append the newly parsed lines to an
  /// existing draft instead of starting a new one — used by "Add more" on
  /// the review screen.
  Future<VoiceOrder> parseVoiceOrder(String transcript, {int? voiceOrderId}) async {
    final query = voiceOrderId != null ? {'voice_order_id': voiceOrderId.toString()} : null;
    final res = await http.post(
      _uri('/voice-orders/parse', query),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'transcript': transcript}),
    );
    _checkOk(res);
    return VoiceOrder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Uploads a raw recording for the backend to transcribe (Gemini, not
  /// on-device) and parse in one step — see voice_sale_screen.dart for why
  /// this replaced on-device speech-to-text. [audioFile] is whatever the
  /// `record` package wrote (a .wav file); the filename's extension is what
  /// the backend uses to infer the audio MIME type.
  Future<VoiceOrder> parseVoiceOrderAudio(File audioFile, {int? voiceOrderId}) async {
    final query = voiceOrderId != null ? {'voice_order_id': voiceOrderId.toString()} : null;
    final request = http.MultipartRequest('POST', _uri('/voice-orders/parse-audio', query))
      ..headers.addAll(_authHeader)
      ..files.add(await http.MultipartFile.fromPath('audio', audioFile.path, contentType: MediaType('audio', 'wav')));
    final streamed = await request.send();
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return VoiceOrder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
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
  }) async {
    final body = <String, dynamic>{};
    if (productId != null) body['product_id'] = productId;
    if (quantity != null) body['quantity'] = quantity;
    if (unit != null) body['unit'] = unit;
    if (prescriptionRef != null) body['prescription_ref'] = prescriptionRef;
    if (skip != null) body['skip'] = skip;
    final res = await http.patch(
      _uri('/voice-orders/$orderId/lines/$lineId'),
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
}

/// Minimal (x, y) pair — avoids pulling in dart:ui's Offset in a file that
/// otherwise has no Flutter widget dependency.
class Offset2D {
  final double x;
  final double y;
  const Offset2D(this.x, this.y);
}
