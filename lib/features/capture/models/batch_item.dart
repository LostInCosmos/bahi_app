import 'dart:typed_data';

import '../../../core/api/api_client.dart';
import '../../../core/utils/pending_photo_store.dart';
import '../../invoice/models/invoice.dart';

/// Where one bill is in the capture flow. Nothing saves itself: even a clean
/// extraction only reaches [pendingConfirm], which still needs a human tap.
/// `needsCrop` is a photo picked from the device that nobody has chosen
/// corners for yet. Distinct from `preparing` because it must NOT be
/// uploaded on its own: multi-select puts a whole stack in this state
/// and each waits for a human, so the resume pass skips them.
enum BatchItemStatus { needsCrop, preparing, ready, processing, pendingConfirm, saved, needsReview, failed }

/// One captured, cropped photo that has not been uploaded yet. A bill spanning
/// several photos ("+ Add another page") has several of these.
///
/// The photo itself is on disk in [PendingPhotoStore] under [photoId], not in
/// memory — so it survives a logout, kill or app update, and fifty queued
/// photos don't all sit in RAM at once. [memoryBytes] is only used if that
/// disk write failed, in which case the page can't outlive this session.
class BatchItemPage {
  final String? photoId;
  final Uint8List? memoryBytes;
  final String filename;
  final List<Offset2D> corners;
  final int rotationDegrees;

  BatchItemPage({
    required this.photoId,
    required this.memoryBytes,
    required this.filename,
    required this.corners,
    required this.rotationDegrees,
  });

  /// The raw photo, or null if its file is gone (e.g. app data was cleared).
  Future<Uint8List?> loadBytes() async {
    final inMemory = memoryBytes;
    if (inMemory != null) return inMemory;
    final id = photoId;
    return id == null ? null : PendingPhotoStore.read(id);
  }

  Map<String, dynamic> toJson() => {
        'photoId': photoId,
        'filename': filename,
        'corners': corners.map((c) => [c.x, c.y]).toList(),
        'rotation': rotationDegrees,
      };

  static BatchItemPage? fromJson(Map<String, dynamic> json) {
    final photoId = json['photoId'] as String?;
    if (photoId == null) return null;
    return BatchItemPage(
      photoId: photoId,
      memoryBytes: null,
      filename: json['filename'] as String? ?? 'bill.jpg',
      corners: (json['corners'] as List<dynamic>)
          .map((c) => Offset2D((c[0] as num).toDouble(), (c[1] as num).toDouble()))
          .toList(),
      rotationDegrees: json['rotation'] as int? ?? 0,
    );
  }
}

class BatchItem {
  final String label;

  /// Photos still waiting to be uploaded — emptied once every page has been
  /// accepted by the server, since [sourceImages] is all that's needed after.
  List<BatchItemPage> pages;

  /// Every page's uploaded/cropped server path, in order. Populated once
  /// preparing finishes (length 1 for an ordinary single-photo bill).
  List<String> sourceImages = [];

  BatchItemStatus status = BatchItemStatus.preparing;

  /// Set when extraction is submitted and cleared at a terminal state —
  /// persisted so a restart resumes polling the SAME job instead of paying
  /// for a second one.
  int? jobId;

  /// Never cleared once set: this item's extraction row for as long as it
  /// exists, so a retry reuses it (ApiClient.retryExtraction) instead of
  /// creating a new row each time.
  int? lastJobId;

  ExtractionResult? result;
  String? errorMessage;
  int? savedInvoiceId;

  /// The folder this bill is in; null is home. Set from wherever the bill was
  /// captured, changed by "Move to…", and sent with the save so the saved
  /// bill lands in the same place. Batches saved before folders existed have no
  /// key for it and load as home.
  int? folderId;

  /// The bill extracted fine and it was the SAVE that failed. Retrying then
  /// means saving again — not re-running extraction, which costs an LLM call
  /// and produces the same result that just failed to save. Not persisted:
  /// after a restart such an item falls back to a fresh extraction, which is
  /// slower but still correct.
  bool failedAtSave = false;

  /// Set while the server is retrying a failed read. The bill is not stuck:
  /// the server tries again at [retryAt], so the card says so instead of an
  /// indefinite spinner or, worse, a failure. Not persisted — a restart
  /// resumes polling the job and picks the retry state up from the server.
  /// When the server first said it was actually working on this bill, as
  /// opposed to leaving it queued. The per-attempt timeout runs from here,
  /// so a bill sitting behind a hundred others is never called failed for
  /// waiting its turn. Not persisted: a restart re-learns it from the server.
  DateTime? processingSince;

  int retryAttempt = 0;
  int retryMax = 3;
  DateTime? retryAt;
  bool get isRetrying => retryAt != null;

  /// Sitting out the server's backoff, so asking about it now would only be
  /// told "retrying" again. [sweepMargin] is how late the server's own
  /// reconciler may be in re-queueing it, since it is not picked up at
  /// `retryAt` but on the next sweep after that.
  bool isBackingOff(Duration sweepMargin) {
    final at = retryAt;
    return at != null && DateTime.now().toUtc().isBefore(at.add(sweepMargin));
  }

  BatchItem({required this.label, required this.pages});

  bool get isUploaded => sourceImages.isNotEmpty;

  /// The words on a card the PHONE gave up on while the server was still
  /// working — see [failedByTimeout].
  static const timedOutMessage = 'This bill is taking longer than expected — please try again.';

  /// Failed only because this phone stopped waiting. The server may well have
  /// finished: it ran the whole read-and-retry cycle (up to four model calls,
  /// queued behind a cap on the provider) while the card had already said
  /// "failed". Trying again should look at that job first, not read the bill
  /// all over again and spend four more calls.
  /// What to do with this bill when the screen starts and finds it saved from
  /// last session.
  StartupAction get startupAction {
    if (!isUploaded) return StartupAction.uploadAgain;
    // "ready" means a job was never submitted last session — start it.
    if (status == BatchItemStatus.ready) return StartupAction.process;
    // "processing" with a job means one WAS submitted and may already be done
    // server-side — resume polling it rather than paying for another.
    if (status == BatchItemStatus.processing && jobId != null) return StartupAction.resumeJob;
    // The phone gave up on it last session, usually while the server was still
    // reading — and the server will have finished by now. Ask it, rather than
    // leave a red card over a bill that is done.
    if (failedByTimeout) return StartupAction.askServer;
    return StartupAction.none;
  }

  bool get failedByTimeout =>
      status == BatchItemStatus.failed && errorMessage == timedOutMessage && lastJobId != null;

  /// Whether the card offers its ↻ button.
  ///
  /// Not while its photos are being uploaded or it is being read, and not
  /// while bills are being chosen. A bill that FAILED always offers it, even
  /// when the failure was the upload itself and nothing is on the server: the
  /// button used to need an uploaded photo, so three bills that timed out
  /// uploading showed a failure badge and no way to try again short of
  /// guessing that the card could be tapped.
  bool canReprocess({required bool choosing}) {
    if (choosing) return false;
    if (status == BatchItemStatus.preparing || status == BatchItemStatus.processing) return false;
    return isUploaded || status == BatchItemStatus.failed;
  }

  /// Whether anything about this item is worth keeping across a restart.
  bool get isPersistable => isUploaded || pages.any((p) => p.photoId != null);

  Map<String, dynamic> toJson() => {
        'label': label,
        'sourceImages': sourceImages,
        // Not-yet-uploaded pages; restored ones are uploaded again on start.
        'pages': pages.where((p) => p.photoId != null).map((p) => p.toJson()).toList(),
        // Extraction runs server-side, independent of this app, so a kill
        // mid-extraction loses nothing — "processing" only rewinds to "ready"
        // (forcing a resubmit) in the narrow window where a job was about to
        // be submitted but jobId isn't set yet.
        'status': (status == BatchItemStatus.processing && jobId == null ? BatchItemStatus.ready : status).name,
        'jobId': jobId,
        'lastJobId': lastJobId,
        'result': result?.toJson(),
        'errorMessage': errorMessage,
        'savedInvoiceId': savedInvoiceId,
        'folderId': folderId,
      };

  static BatchItem? fromJson(Map<String, dynamic> json) {
    final sourceImages = (json['sourceImages'] as List<dynamic>? ?? []).map((e) => e as String).toList();
    final pages = <BatchItemPage>[];
    for (final p in json['pages'] as List<dynamic>? ?? []) {
      final page = BatchItemPage.fromJson(p as Map<String, dynamic>);
      if (page != null) pages.add(page);
    }
    if (sourceImages.isEmpty && pages.isEmpty) return null;

    final item = BatchItem(label: json['label'] as String? ?? 'Photo', pages: sourceImages.isEmpty ? pages : []);
    item.sourceImages = sourceImages;
    // A bill that never finished uploading comes back as "preparing",
    // whatever it was when saved — including a failed upload, which is
    // simply tried again.
    //
    // Except one still waiting to be cropped: that must come back as
    // `needsCrop`, or the resume pass would upload a stack of uncropped
    // photos the shopkeeper never looked at.
    item.status = sourceImages.isEmpty
        ? (json['status'] == BatchItemStatus.needsCrop.name
            ? BatchItemStatus.needsCrop
            : BatchItemStatus.preparing)
        : BatchItemStatus.values.firstWhere((v) => v.name == json['status'], orElse: () => BatchItemStatus.ready);
    item.jobId = json['jobId'] as int?;
    // Batches saved before lastJobId existed have no key for it — jobId is
    // the same value for any item whose first submission was still running.
    item.lastJobId = json['lastJobId'] as int? ?? item.jobId;
    item.errorMessage = json['errorMessage'] as String?;
    item.savedInvoiceId = json['savedInvoiceId'] as int?;
    item.folderId = json['folderId'] as int?;
    final resultJson = json['result'] as Map<String, dynamic>?;
    if (resultJson != null) item.result = ExtractionResult.fromJson(resultJson);
    return item;
  }
}

/// What a bill restored at startup needs, decided in one place.
enum StartupAction { uploadAgain, process, resumeJob, askServer, none }
