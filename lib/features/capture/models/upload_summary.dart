/// One row of `GET /invoices/extract` — a bill this SHOP has uploaded,
/// as opposed to one this DEVICE happens to be holding.
///
/// Until this existed the phone could only show bills captured on itself,
/// so a reinstall, a second phone, or signing in on a new handset showed
/// an empty capture screen however much history the shop had. One shop
/// had 214 uploads on the server and saw none of them.
///
/// Deliberately thin, exactly as the endpoint is: no result, no raw
/// response, no validation issues — those are ~1,827 of a row's ~2,005
/// bytes, and a page of fifty is drawn from thumbnails and a status.
/// `issueCount` is the one thing carried from them, because it is what
/// separates a bill that wants a person from one that is merely waiting
/// to be saved. The full result is fetched for the one bill that gets
/// opened (`getExtractionJob`).
class UploadSummary {
  final int jobId;
  final String status;
  final String sourceImage;
  final DateTime createdAt;

  /// Set once the bill has been saved as an invoice; null while it is
  /// still only an upload.
  final int? invoiceId;

  /// The folder the saved invoice went into — null for anything unsaved,
  /// which is the same thing as unfiled: a bill has no folder until
  /// someone files it by saving.
  final int? folderId;

  /// How many things validation flagged. 0 for a clean read, and for a
  /// bill that has not been read yet.
  final int issueCount;

  /// When the server intends to try again, while it is backing off.
  final DateTime? retryAt;

  const UploadSummary({
    required this.jobId,
    required this.status,
    required this.sourceImage,
    required this.createdAt,
    this.invoiceId,
    this.folderId,
    this.issueCount = 0,
    this.retryAt,
  });

  factory UploadSummary.fromJson(Map<String, dynamic> json) => UploadSummary(
        jobId: json['job_id'] as int,
        status: json['status'] as String? ?? 'queued',
        sourceImage: json['source_image'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        invoiceId: json['invoice_id'] as int?,
        folderId: json['folder_id'] as int?,
        // Absent on a server older than the field; absent means none, not
        // unknown, so the card reads "Check & save" exactly as it used to.
        issueCount: (json['issue_count'] as num?)?.toInt() ?? 0,
        retryAt: json['retry_at'] == null
            ? null
            : DateTime.parse(json['retry_at'] as String).toLocal(),
      );

  bool get isSaved => invoiceId != null;
}

/// A page of them. Keyset, not an offset: uploads arrive while someone is
/// scrolling, and an offset would skip or repeat rows as the list shifts.
class UploadPage {
  final List<UploadSummary> uploads;

  /// Pass back as `beforeId` for the next page. Null means this is the last.
  final int? nextBeforeId;

  const UploadPage({required this.uploads, this.nextBeforeId});

  factory UploadPage.fromJson(Map<String, dynamic> json) => UploadPage(
        uploads: (json['jobs'] as List<dynamic>? ?? const [])
            .map((e) => UploadSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextBeforeId: json['next_before_id'] as int?,
      );
}
