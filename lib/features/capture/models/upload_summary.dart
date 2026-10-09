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
String? _text(Object? value) {
  final text = (value as String? ?? '').trim();
  return text.isEmpty ? null : text;
}

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

  /// Who the bill is from, and its number: the saved invoice's own values once
  /// saved, otherwise what was read. Null until a read has produced them, and
  /// on a server older than the fields. They label the card and feed search.
  final String? sellerName;
  final String? invoiceNo;

  const UploadSummary({
    required this.jobId,
    required this.status,
    required this.sourceImage,
    required this.createdAt,
    this.invoiceId,
    this.folderId,
    this.issueCount = 0,
    this.retryAt,
    this.sellerName,
    this.invoiceNo,
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
        sellerName: _text(json['seller_name']),
        invoiceNo: _text(json['invoice_no']),
      );

  bool get isSaved => invoiceId != null;

  /// The same bill, filed somewhere else. A separate method rather than a
  /// general copyWith because the folder is NULLABLE — null means home — and
  /// a copyWith cannot tell "set it to null" from "leave it alone".
  UploadSummary withFolder(int? folder) => UploadSummary(
        jobId: jobId,
        status: status,
        sourceImage: sourceImage,
        createdAt: createdAt,
        invoiceId: invoiceId,
        folderId: folder,
        issueCount: issueCount,
        retryAt: retryAt,
        sellerName: sellerName,
        invoiceNo: invoiceNo,
      );
}

/// A page of them. Keyset, not an offset: uploads arrive while someone is
/// scrolling, and an offset would skip or repeat rows as the list shifts.
class UploadPage {
  final List<UploadSummary> uploads;

  /// Pass back as `beforeId` for the next page. Null means this is the last.
  final int? nextBeforeId;

  /// How many of the shop's bills are in each category, per folder
  /// (`root` for none) — over EVERY bill, not just this page. Sent with the
  /// first page only; null on later pages, and on a server that predates
  /// it, in which case the list tallies what it has loaded.
  final Map<String, Map<String, int>>? counts;

  const UploadPage({required this.uploads, this.nextBeforeId, this.counts});

  factory UploadPage.fromJson(Map<String, dynamic> json) => UploadPage(
        uploads: (json['jobs'] as List<dynamic>? ?? const [])
            .map((e) => UploadSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextBeforeId: json['next_before_id'] as int?,
        counts: (json['counts'] as Map<String, dynamic>?)?.map(
          (folder, byCategory) => MapEntry(
            folder,
            (byCategory as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toInt())),
          ),
        ),
      );
}
