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
