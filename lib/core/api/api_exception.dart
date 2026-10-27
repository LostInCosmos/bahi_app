class ApiException implements Exception {
  final int statusCode;
  final String message;
  /// The raw `detail` field from the response body, when the body was JSON
  /// with a structured detail (a String, or a Map like
  /// `{"error": "validation_failed", "issues": [...]}`). Callers that need
  /// to branch on the specific error kind (validation vs. structural
  /// extraction failure) should inspect this instead of parsing [message].
  final dynamic detail;

  /// The request field a refusal is about, when the server names it beside
  /// the detail: `{"detail": "Enter a 10-digit phone number.", "field":
  /// "buyer_phone"}` (DAS-150). Null otherwise.
  final String? field;

  ApiException(this.statusCode, this.message, [this.detail, this.field]);

  /// The server's machine-readable kind, when the body carried one —
  /// `{"detail": {"error": "account_deleted", …}}` or a top-level
  /// `{"error": …, "message": …}` (both are read by `ApiClient`). Null for a
  /// plain-text detail.
  String? get errorCode {
    final d = detail;
    return d is Map ? d['error'] as String? : null;
  }

  @override
  String toString() => message;
}
