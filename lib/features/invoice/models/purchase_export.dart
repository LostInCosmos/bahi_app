/// A purchases spreadsheet from `GET /export/excel`, with what the server
/// said about it in the response headers.
///
/// The headers matter for a folder export: a server that predates the
/// `folder_id` filter ignores it and sends every bill, which would be shared
/// as if it were the folder's. A server that does filter says so by echoing
/// the id in `X-Export-Folder-Id`; no echo means an old server.
class PurchaseExport {
  final List<int> bytes;

  /// `X-Export-Folder-Id` — set only when the request carried a `folder_id`.
  final int? folderId;

  /// `X-Export-Bill-Count` — how many bills are in the file.
  final int? billCount;

  /// `X-Export-Date-Basis` — which date the range was matched on (`bill` or
  /// `uploaded`). A server that predates `date_basis` does not send it, and
  /// would have matched the range on the bill date.
  final String? dateBasis;

  /// `X-Export-Excluded-Under-Review` — how many bills were left out because
  /// they are still being checked (DAS-71). 0 when none, and 0 when the header
  /// is absent: an older server leaves nothing out.
  final int excludedUnderReview;

  const PurchaseExport({
    required this.bytes,
    this.folderId,
    this.billCount,
    this.dateBasis,
    this.excludedUnderReview = 0,
  });

  /// [headers] is `http.Response.headers`, whose keys are lower case.
  factory PurchaseExport.fromResponse(List<int> bytes, Map<String, String> headers) => PurchaseExport(
        bytes: bytes,
        folderId: int.tryParse(headers['x-export-folder-id'] ?? ''),
        billCount: int.tryParse(headers['x-export-bill-count'] ?? ''),
        dateBasis: headers['x-export-date-basis'],
        excludedUnderReview: int.tryParse(headers['x-export-excluded-under-review'] ?? '') ?? 0,
      );
}

/// What the range on Purchases selects, in the words the export sheet shows.
/// The range is always matched on the date a bill was uploaded.
String exportRangeLabel({String? start, String? end, String? vendorGstin}) {
  final dates = switch ((start, end)) {
    (null, null) => 'All saved bills',
    (final s?, null) => 'Bills uploaded from $s',
    (null, final e?) => 'Bills uploaded up to $e',
    (final s?, final e?) => 'Bills uploaded $s to $e',
  };
  final gstin = vendorGstin?.trim() ?? '';
  return gstin.isEmpty ? dates : '$dates · supplier $gstin';
}

/// The sentence for bills an export left out because they are still being
/// checked, or null when it left none out.
String? excludedNote(int excluded) => excluded <= 0
    ? null
    : excluded == 1
        ? '1 bill is still being checked and was not included.'
        : '$excluded bills are still being checked and were not included.';
