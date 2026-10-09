part of '../../../core/api/api_client.dart';

extension InvoiceApi on ApiClient {
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

  /// The corrected bill photo, served from the device if it has been seen
  /// before. A given source path's bytes never change — the server writes a
  /// new uuid on re-crop — so a hit needs no revalidation, and this is the
  /// only place that has to know the cache exists. See [BillImageCache].
  ///
  /// A cache hit never reaches the server's permission check, so it is only
  /// served for the signed-in shop's own paths (`<tenantId>/…`). Anything
  /// else goes to the server, which refuses it the normal way.
  Future<Uint8List> fetchImage(String sourceImage) async {
    final tid = tenantId;
    final ownPath = tid != null && sourceImage.startsWith('$tid/');
    if (ownPath) {
      final cached = await BillImageCache.read(sourceImage);
      if (cached != null) return cached;
    }
    final res = await http.get(_uri('/invoices/image/$sourceImage'), headers: _authHeader);
    _checkOk(res);
    await BillImageCache.write(sourceImage, res.bodyBytes);
    return res.bodyBytes;
  }

  /// [extraSourceImages] are additional pages of the SAME bill (see
  /// CaptureScreen's multi-page capture) — sent as repeated form fields
  /// (not a Map, which can't hold duplicate keys) so the backend receives
  /// them as a real list and stitches every page into one Gemini call.
  ///
  /// Returns immediately with a job id — extraction now runs in a
  /// background worker, not inline in this request — so the caller polls
  /// getExtractionJob() until it reaches a terminal status.
  Future<int> submitExtraction(String sourceImage, {List<String> extraSourceImages = const []}) async {
    final request = http.MultipartRequest('POST', _uri('/invoices/extract'))
      ..headers.addAll(_authHeader)
      ..fields['source_image'] = sourceImage;
    for (final img in extraSourceImages) {
      request.files.add(http.MultipartFile.fromString('extra_source_images', img));
    }
    final streamed = await request.send();
    final res = await http.Response.fromStream(streamed);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['job_id'] as int;
  }

  /// Re-queues an already-submitted job for another Gemini attempt — the
  /// SAME job id, not a new one (see api/v1/extraction.py's retry_extraction:
  /// calling submitExtraction again on a "resend to Gemini" tap used to
  /// create a brand-new row per retry, splitting one bill's real attempt
  /// count and Gemini cost across several admin-dashboard entries instead
  /// of one honest total). Same submit-then-poll shape as submitExtraction.
  Future<int> retryExtraction(int jobId) async {
    final res = await http.post(_uri('/invoices/extract/$jobId/retry'), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['job_id'] as int;
  }

  /// Status for every bill still in flight, in ONE request the server holds
  /// open until something changes.
  ///
  /// Replaces a 2-second timer per bill: 1000 bills used to mean ~500
  /// requests a second, each a `SELECT *` carrying ~2 KB of result JSON to
  /// deliver ~13 bytes of status. This is one request per ~25s for the whole
  /// batch, and it returns the instant a bill finishes rather than up to two
  /// seconds later.
  ///
  /// The timeout is longer than the server's hold on purpose — the server
  /// answers at ~25s, so anything past that is a dead connection, not a slow
  /// one. A throw here means "ask again", never "the bill failed": every
  /// request re-reads current state, so nothing is missed by reconnecting.
  Future<JobStatusBatch> jobStatuses(List<int> jobIds, {bool wait = true}) async {
    final res = await http
        .post(
          _uri('/invoices/extract/status'),
          headers: {..._authHeader, 'Content-Type': 'application/json'},
          body: jsonEncode({'job_ids': jobIds, 'wait': wait}),
        )
        .timeout(const Duration(seconds: 40));
    _checkOk(res);
    return JobStatusBatch.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Every bill this SHOP has uploaded, newest first — not just the ones
  /// this device is holding. Without it a reinstall or a second phone
  /// shows an empty capture screen however long the shop's history is.
  ///
  /// Keyset paging on [beforeId], replayed from the previous page's
  /// `nextBeforeId`; the server caps [limit] at 200.
  ///
  /// [categories] (status boxes: working, check, review, saved, failed) and
  /// [folder] (`root` for home, or a folder id) narrow the list on the server
  /// before it is paged, so a filtered list finds its bills on any page.
  Future<UploadPage> listUploads({
    int limit = 50,
    int? beforeId,
    Set<String> categories = const {},
    String? folder,
  }) async {
    final query = {
      'limit': '$limit',
      if (beforeId != null) 'before_id': '$beforeId',
      if (categories.isNotEmpty) 'category': (categories.toList()..sort()).join(','),
      if (folder != null) 'folder': folder,
    };
    final res = await http.get(_uri('/invoices/extract', query), headers: _authHeader);
    _checkOk(res);
    return UploadPage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// File many bills at once: unsaved uploads by job id, saved bills by
  /// invoice id. One request, and the only way to file an upload — a single
  /// bill is a batch of one. Bills the server could not move are simply
  /// missing from the reply.
  Future<BulkMoveReply> bulkMove({
    List<int> jobIds = const [],
    List<int> invoiceIds = const [],
    required int? folderId,
  }) async {
    final res = await http.post(
      _uri('/invoices/bulk-move'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'job_ids': jobIds, 'invoice_ids': invoiceIds, 'folder_id': folderId}),
    );
    _checkOk(res);
    return BulkMoveReply.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Take many uploads out of this shop's list in one request. Bills the
  /// server would not discard (saved, still being read) are missing from the
  /// reply.
  Future<BulkDiscardReply> bulkDiscard(List<int> jobIds) async {
    final res = await http.post(
      _uri('/invoices/bulk-discard'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'job_ids': jobIds}),
    );
    _checkOk(res);
    return BulkDiscardReply.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ExtractionJob> getExtractionJob(int jobId) async {
    final res = await http.get(_uri('/invoices/extract/$jobId'), headers: _authHeader);
    _checkOk(res);
    return ExtractionJob.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
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

  Future<int> saveInvoice(
    InvoiceData invoice,
    ExtractionMeta meta, {
    bool overrideErrors = false,
    bool gstinConfirmed = false,
    int? confirmedVendorId,
    int? folderId,
  }) async {
    final res = await http.post(
      _uri('/invoices'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'invoice': invoice.toJson(),
        'extraction_meta': meta.toJson(),
        'override_errors': overrideErrors,
        'gstin_confirmed': gstinConfirmed,
        'confirmed_vendor_id': confirmedVendorId,
        'folder_id': folderId,
      }),
    );
    _checkOk(res);
    return jsonDecode(res.body)['invoice_id'] as int;
  }

  /// Who this bill is from, and whether saving will need the shopkeeper to
  /// confirm the GSTIN. Called while the review screen is still being read so
  /// that Save opens the confirmation with no wait — the fuzzy vendor search
  /// is the slow part and does not depend on anything they do on that screen.
  ///
  /// Advisory only: the save endpoint runs the same check and is the one that
  /// decides. A failure here is not an error, just a lost head start.
  Future<VendorHint?> lookupVendor(InvoiceData invoice) async {
    try {
      final res = await http.post(
        _uri('/invoices/vendor-lookup'),
        headers: {..._authHeader, 'Content-Type': 'application/json'},
        body: jsonEncode(invoice.toJson()),
      );
      if (res.statusCode >= 400) return null;
      return VendorHint.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<List<InvoiceSummary>> listInvoices({
    String? startDate,
    String? endDate,
    String? vendorGstin,
    int? folderId,
    bool unfiled = false,
  }) async {
    final query = <String, String>{};
    if (startDate != null) query['start_date'] = startDate;
    if (endDate != null) query['end_date'] = endDate;
    if (vendorGstin != null && vendorGstin.isNotEmpty) query['vendor_gstin'] = vendorGstin;
    // Neither given = every bill, in any folder. `unfiled` is home.
    if (folderId != null) {
      query['folder_id'] = '$folderId';
    } else if (unfiled) {
      query['unfiled'] = 'true';
    }

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
}
