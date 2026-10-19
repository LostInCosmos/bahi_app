import '../../../core/api/api_client.dart';
import '../models/bulk.dart';
import '../models/upload_summary.dart';

/// The capture screen's own endpoints: the shop's uploads list and filing or
/// discarding many uploads at once. They sit under `/invoices` on the server,
/// but they return capture's models, so they live with capture — invoice's
/// API knows nothing about the capture screen.
extension CaptureApi on ApiClient {
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
  /// [counts] false skips the server's tally on the first page (DAS-105) —
  /// for a refresh whose boxes are already right, such as coming back from
  /// a bill nothing happened to. An older server ignores it and sends the
  /// tally anyway, which is harmless.
  Future<UploadPage> listUploads({
    int limit = 50,
    int? beforeId,
    Set<String> categories = const {},
    String? folder,
    bool counts = true,
  }) async {
    final res = await get('/invoices/extract', query: {
      'limit': '$limit',
      if (beforeId != null) 'before_id': '$beforeId',
      if (categories.isNotEmpty) 'category': (categories.toList()..sort()).join(','),
      if (folder != null) 'folder': folder,
      if (!counts) 'counts': 'false',
    });
    return UploadPage.fromJson(ApiClient.jsonObject(res));
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
    final res = await postJson(
      '/invoices/bulk-move',
      {'job_ids': jobIds, 'invoice_ids': invoiceIds, 'folder_id': folderId},
      timeout: ApiClient.workTimeout,
    );
    return BulkMoveReply.fromJson(ApiClient.jsonObject(res));
  }

  /// Take many uploads out of this shop's list in one request. Bills the
  /// server would not discard (saved, still being read) are missing from the
  /// reply.
  Future<BulkDiscardReply> bulkDiscard(List<int> jobIds) async {
    final res = await postJson('/invoices/bulk-discard', {'job_ids': jobIds}, timeout: ApiClient.workTimeout);
    return BulkDiscardReply.fromJson(ApiClient.jsonObject(res));
  }
}
