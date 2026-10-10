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
    final res = await _multipart('/invoices/preprocess', (request) {
      request
        ..fields['corners'] = jsonEncode(corners.map((c) => {'x': c.x, 'y': c.y}).toList())
        ..fields['rotation_degrees'] = rotationDegrees.toString()
        ..files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: filename));
    });
    return ApiClient._object(res)['source_image'] as String;
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
    final res = await _get('/invoices/image/$sourceImage', timeout: ApiClient.transferTimeout);
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
    final res = await _multipart('/invoices/extract', (request) {
      request.fields['source_image'] = sourceImage;
      for (final img in extraSourceImages) {
        request.files.add(http.MultipartFile.fromString('extra_source_images', img));
      }
    }, timeout: ApiClient.readTimeout);
    return ApiClient._object(res)['job_id'] as int;
  }

  /// Re-queues an already-submitted job for another Gemini attempt — the
  /// SAME job id, not a new one (see api/v1/extraction.py's retry_extraction:
  /// calling submitExtraction again on a "resend to Gemini" tap used to
  /// create a brand-new row per retry, splitting one bill's real attempt
  /// count and Gemini cost across several admin-dashboard entries instead
  /// of one honest total). Same submit-then-poll shape as submitExtraction.
  Future<int> retryExtraction(int jobId) async =>
      ApiClient._object(await _post('/invoices/extract/$jobId/retry'))['job_id'] as int;

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
    final res = await _postJson(
      '/invoices/extract/status',
      {'job_ids': jobIds, 'wait': wait},
      timeout: ApiClient.heldTimeout,
    );
    return JobStatusBatch.fromJson(ApiClient._object(res));
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
    final res = await _get('/invoices/extract', query: {
      'limit': '$limit',
      if (beforeId != null) 'before_id': '$beforeId',
      if (categories.isNotEmpty) 'category': (categories.toList()..sort()).join(','),
      if (folder != null) 'folder': folder,
    });
    return UploadPage.fromJson(ApiClient._object(res));
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
    final res = await _postJson(
      '/invoices/bulk-move',
      {'job_ids': jobIds, 'invoice_ids': invoiceIds, 'folder_id': folderId},
      timeout: ApiClient.workTimeout,
    );
    return BulkMoveReply.fromJson(ApiClient._object(res));
  }

  /// Take many uploads out of this shop's list in one request. Bills the
  /// server would not discard (saved, still being read) are missing from the
  /// reply.
  Future<BulkDiscardReply> bulkDiscard(List<int> jobIds) async {
    final res = await _postJson('/invoices/bulk-discard', {'job_ids': jobIds}, timeout: ApiClient.workTimeout);
    return BulkDiscardReply.fromJson(ApiClient._object(res));
  }

  Future<ExtractionJob> getExtractionJob(int jobId) async =>
      ExtractionJob.fromJson(ApiClient._object(await _get('/invoices/extract/$jobId')));

  Future<RevalidateResult> revalidateInvoice(InvoiceData invoice) async {
    final res = await _postJson('/invoices/revalidate', invoice.toJson(), timeout: ApiClient.workTimeout);
    return RevalidateResult.fromJson(ApiClient._object(res));
  }

  Future<int> saveInvoice(
    InvoiceData invoice,
    ExtractionMeta meta, {
    bool overrideErrors = false,
    bool gstinConfirmed = false,
    int? confirmedVendorId,
    int? folderId,
  }) async {
    final res = await _postJson(
        '/invoices',
        {
          'invoice': invoice.toJson(),
          'extraction_meta': meta.toJson(),
          'override_errors': overrideErrors,
          'gstin_confirmed': gstinConfirmed,
          'confirmed_vendor_id': confirmedVendorId,
          'folder_id': folderId,
        },
        timeout: ApiClient.workTimeout);
    return ApiClient._object(res)['invoice_id'] as int;
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
      final res = await _postJson('/invoices/vendor-lookup', invoice.toJson(), timeout: ApiClient.workTimeout);
      return VendorHint.fromJson(ApiClient._object(res));
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
    final res = await _get('/invoices', query: {
      ...ApiClient._dateRange(startDate, endDate),
      if (vendorGstin != null && vendorGstin.isNotEmpty) 'vendor_gstin': vendorGstin,
      // Neither given = every bill, in any folder. `unfiled` is home.
      if (folderId != null) 'folder_id': '$folderId' else if (unfiled) 'unfiled': 'true',
    });
    return ApiClient._list(res).map((e) => InvoiceSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<InvoiceDetail> getInvoiceDetail(int invoiceId) async =>
      InvoiceDetail.fromJson(ApiClient._object(await _get('/invoices/$invoiceId')));

  /// Reverses the stock this invoice added to inventory, then removes it.
  /// Throws ApiException(409) if some of that stock has already been sold —
  /// the caller should surface `.message` rather than retry.
  Future<void> deleteInvoice(int invoiceId) => _delete('/invoices/$invoiceId');

  /// Send a saved bill back to Check & save — or Needs review, if its read had
  /// issues — in the folder it was filed in. The bill's read stays; the
  /// invoice goes. [removeStock] is the shopkeeper's answer to whether the
  /// stock it added leaves inventory too (required: never assumed). Throws
  /// ApiException(409) if some of that stock has already been sold, or if
  /// there is no read to go back to — surface `.message`.
  Future<void> unsaveInvoice(int invoiceId, {required bool removeStock}) =>
      _postJson('/invoices/$invoiceId/unsave', {'remove_stock': removeStock});

  Future<Uint8List> exportExcel({
    String? startDate,
    String? endDate,
    String? vendorGstin,
  }) async {
    final res = await _get('/export/excel',
        query: {
          ...ApiClient._dateRange(startDate, endDate),
          if (vendorGstin != null && vendorGstin.isNotEmpty) 'vendor_gstin': vendorGstin,
        },
        timeout: ApiClient.transferTimeout);
    return res.bodyBytes;
  }
}
