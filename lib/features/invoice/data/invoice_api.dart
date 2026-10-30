import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../core/api/api_client.dart';
import '../../../core/disk/bill_image_cache.dart';
import '../../../core/utils/offset_2d.dart';
import '../models/invoice.dart';
import '../models/job_status.dart';
import '../models/purchase_export.dart';

/// What the purchase range means: bills by the date they were UPLOADED, not
/// the date printed on them. Sent only with a date, because without one the
/// basis changes nothing; the sales range stays on [ApiClient.dateRange].
const _uploadedBasis = 'uploaded';

Map<String, String> _purchaseDateRange(String? startDate, String? endDate) => {
      ...ApiClient.dateRange(startDate, endDate),
      if (startDate != null || endDate != null) 'date_basis': _uploadedBasis,
    };

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
    final res = await multipart('/invoices/preprocess', (request) {
      request
        ..fields['corners'] = jsonEncode(corners.map((c) => {'x': c.x, 'y': c.y}).toList())
        ..fields['rotation_degrees'] = rotationDegrees.toString()
        ..files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: filename));
    });
    return ApiClient.jsonObject(res)['source_image'] as String;
  }

  /// The corrected bill photo, served from the device if it has been seen
  /// before. A given source path's bytes never change on their own — the
  /// server writes a new uuid on re-crop — EXCEPT a photo rotation (DAS-72),
  /// which overwrites the same path and bumps [imageRev]. So the cache is
  /// keyed by path alone at rev 0 (the overwhelming majority — keeps every
  /// cache entry written before this change valid) and by `path?v=rev` once
  /// rev is bumped, which is a guaranteed miss until the rotated bytes are
  /// fetched and stored under that key; the server ignores the query string,
  /// so it changes nothing about what is actually requested. This is the
  /// only place that has to know the cache exists. See [BillImageCache].
  ///
  /// A cache hit never reaches the server's permission check, so it is only
  /// served for the signed-in shop's own paths (`<tenantId>/…`). Anything
  /// else goes to the server, which refuses it the normal way.
  ///
  /// [width] asks for a copy no wider than needed (DAS-105): the server snaps
  /// it to 320/640/1280 and answers `X-Image-Width`; a thumbnail at 640 is
  /// ~60 KB where the original is ~780 KB. Cached under its own key
  /// (`path?w=640`, then `&v=rev`), so a full-size fetch and a thumbnail of
  /// the same bill are two entries. An older server ignores `w` and sends
  /// the original, which is then simply cached under that key.
  Future<Uint8List> fetchImage(String sourceImage, {int imageRev = 0, int? width}) async {
    final tid = tenantId;
    final ownPath = tid != null && sourceImage.startsWith('$tid/');
    final key = imageCacheKey(sourceImage, imageRev: imageRev, width: width);
    if (ownPath) {
      final cached = await BillImageCache.read(key);
      if (cached != null) return cached;
    }
    final res = await get('/invoices/image/$key', timeout: ApiClient.transferTimeout);
    await BillImageCache.write(key, res.bodyBytes);
    return res.bodyBytes;
  }

  /// The cache key, which is also the request path's query: `w` first, then
  /// `v`, neither when zero/absent — so every entry written before either
  /// existed is still found.
  static String imageCacheKey(String sourceImage, {int imageRev = 0, int? width}) {
    final params = [if (width != null) 'w=$width', if (imageRev > 0) 'v=$imageRev'];
    return params.isEmpty ? sourceImage : '$sourceImage?${params.join('&')}';
  }

  /// [extraSourceImages] are additional pages of the SAME bill (see
  /// CaptureScreen's multi-page capture) — sent as repeated form fields
  /// (not a Map, which can't hold duplicate keys) so the backend receives
  /// them as a real list and stitches every page into one Gemini call.
  ///
  /// [folderId] files the upload from the start (DAS-151), so the server's
  /// own copy — its list, its counts, its auto-save — is in the folder the
  /// bill was added in. A server that predates it ignores the field, and the
  /// phone re-files the bill once its row is listed (see `refileOnServer`).
  ///
  /// Returns immediately with a job id — extraction now runs in a
  /// background worker, not inline in this request — so the caller polls
  /// getExtractionJob() until it reaches a terminal status.
  Future<int> submitExtraction(String sourceImage,
      {List<String> extraSourceImages = const [], int? folderId}) async {
    final res = await multipart('/invoices/extract', (request) {
      request.fields['source_image'] = sourceImage;
      if (folderId != null) request.fields['folder_id'] = '$folderId';
      for (final img in extraSourceImages) {
        request.files.add(http.MultipartFile.fromString('extra_source_images', img));
      }
    }, timeout: ApiClient.readTimeout);
    return ApiClient.jsonObject(res)['job_id'] as int;
  }

  /// Re-queues an already-submitted job for another Gemini attempt — the
  /// SAME job id, not a new one (see api/v1/extraction.py's retry_extraction:
  /// calling submitExtraction again on a "resend to Gemini" tap used to
  /// create a brand-new row per retry, splitting one bill's real attempt
  /// count and Gemini cost across several admin-dashboard entries instead
  /// of one honest total). Same submit-then-poll shape as submitExtraction.
  Future<int> retryExtraction(int jobId) async =>
      ApiClient.jsonObject(await post('/invoices/extract/$jobId/retry'))['job_id'] as int;

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
  ///
  /// [seen] (DAS-132) is what the phone's cards draw for each job; the server
  /// answers at once when any job differs from it, instead of waiting out the
  /// hold. A server older than the field ignores it.
  Future<JobStatusBatch> jobStatuses(List<int> jobIds, {bool wait = true, Map<int, String>? seen}) async {
    final res = await postJson(
      '/invoices/extract/status',
      {
        'job_ids': jobIds,
        'wait': wait,
        if (seen != null) 'seen': {for (final e in seen.entries) '${e.key}': e.value},
      },
      timeout: ApiClient.heldTimeout,
    );
    return JobStatusBatch.fromJson(ApiClient.jsonObject(res));
  }

  Future<ExtractionJob> getExtractionJob(int jobId) async =>
      ExtractionJob.fromJson(ApiClient.jsonObject(await get('/invoices/extract/$jobId')));

  Future<RevalidateResult> revalidateInvoice(InvoiceData invoice) async {
    final res = await postJson('/invoices/revalidate', invoice.toJson(), timeout: ApiClient.workTimeout);
    return RevalidateResult.fromJson(ApiClient.jsonObject(res));
  }

  Future<int> saveInvoice(
    InvoiceData invoice,
    ExtractionMeta meta, {
    bool overrideErrors = false,
    int? folderId,
  }) async {
    final res = await postJson(
        '/invoices',
        {
          'invoice': invoice.toJson(),
          'extraction_meta': meta.toJson(),
          'override_errors': overrideErrors,
          'folder_id': folderId,
        },
        timeout: ApiClient.workTimeout);
    return ApiClient.jsonObject(res)['invoice_id'] as int;
  }

  /// Saves what the server read from this bill — its current result, the
  /// machine's or, if our team has corrected it, theirs (DAS-71). The phone
  /// sends no values, so it cannot overwrite a correction, and clean and
  /// flagged bills save the same way. Throws ApiException: 404 (not this
  /// shop's job, or its folder is gone), 409 (already saved), 422 (not read yet).
  Future<SavedJob> saveJob(int jobId, {int? folderId}) async {
    final res = await postJson(
        '/invoices/extract/$jobId/save', {if (folderId != null) 'folder_id': folderId},
        timeout: ApiClient.workTimeout);
    final body = ApiClient.jsonObject(res);
    return SavedJob(invoiceId: body['invoice_id'] as int, reviewState: body['review_state'] as String?);
  }

  Future<List<InvoiceSummary>> listInvoices({
    String? startDate,
    String? endDate,
    String? vendorGstin,
    int? folderId,
    bool unfiled = false,
  }) async {
    final res = await get('/invoices', query: {
      ..._purchaseDateRange(startDate, endDate),
      if (vendorGstin != null && vendorGstin.isNotEmpty) 'vendor_gstin': vendorGstin,
      // Neither given = every bill, in any folder. `unfiled` is home.
      if (folderId != null) 'folder_id': '$folderId' else if (unfiled) 'unfiled': 'true',
    });
    return ApiClient.listOf(res, InvoiceSummary.fromJson);
  }

  Future<InvoiceDetail> getInvoiceDetail(int invoiceId) async =>
      InvoiceDetail.fromJson(ApiClient.jsonObject(await get('/invoices/$invoiceId')));

  /// Reverses the stock this invoice added to inventory, then removes it.
  /// Throws ApiException(409) if some of that stock has already been sold —
  /// the caller should surface `.message` rather than retry.
  Future<void> deleteInvoice(int invoiceId) => delete('/invoices/$invoiceId');

  /// Send a saved bill back to Not saved — or Needs review, if its read had
  /// issues — in the folder it was filed in. The bill's read stays; the
  /// invoice goes. [removeStock] is the shopkeeper's answer to whether the
  /// stock it added leaves inventory too (required: never assumed). Throws
  /// ApiException(409) if some of that stock has already been sold, or if
  /// there is no read to go back to — surface `.message`.
  Future<bool> unsaveInvoice(int invoiceId, {required bool removeStock}) async {
    final res = await postJson('/invoices/$invoiceId/unsave', {'remove_stock': removeStock});
    // Whether the stock left inventory, as the server says. A server that
    // predates the field is taken at the shopkeeper's word.
    return (ApiClient.jsonObject(res)['stock_removed'] as bool?) ?? removeStock;
  }

  /// The purchases spreadsheet. A date range selects the bills by the date they
  /// were uploaded. With [folderId], only the bills filed directly
  /// in that folder. Throws if the server did not confirm the folder: an old
  /// server ignores the filter and would send every bill.
  Future<PurchaseExport> exportExcel({
    String? startDate,
    String? endDate,
    String? vendorGstin,
    int? folderId,
  }) async {
    final res = await get('/export/excel',
        query: {
          ..._purchaseDateRange(startDate, endDate),
          if (vendorGstin != null && vendorGstin.isNotEmpty) 'vendor_gstin': vendorGstin,
          if (folderId != null) 'folder_id': '$folderId',
        },
        timeout: ApiClient.transferTimeout);
    final export = PurchaseExport.fromResponse(res.bodyBytes, res.headers);
    if (folderId != null && export.folderId != folderId) {
      throw ApiException(res.statusCode, "This server can't export a single folder yet.");
    }
    // A range was sent as "uploaded between": a server that ignored that
    // would have matched the bill dates, and the file would not be the set
    // the screen shows.
    if ((startDate != null || endDate != null) && export.dateBasis != _uploadedBasis) {
      throw ApiException(res.statusCode, "This server can't export by upload date yet.");
    }
    return export;
  }
}
