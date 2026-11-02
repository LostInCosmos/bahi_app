import 'dart:async';

import 'package:http/http.dart' as http;

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

/// The server did not answer within the request's timeout. Still a
/// [TimeoutException], so a caller that waits on one sees no difference;
/// only what a shopkeeper reads from `'$e'` changes — not
/// "TimeoutException after 0:00:30.000000: Future not completed".
class ServerTimedOut extends TimeoutException {
  ServerTimedOut(Duration timeout) : super('The server did not answer in time', timeout);

  @override
  String toString() => 'The server took too long to answer. Try again.';
}

/// The connection failed before any answer: no network, a closed pool
/// connection, a server that is down. Still an [http.ClientException], so
/// the client's own retry rule and every `isA<ClientException>` hold; only
/// the text a shopkeeper reads changes — not "ClientException: Connection
/// reset by peer, uri=https://…".
class ServerUnreachable extends http.ClientException {
  ServerUnreachable(http.ClientException cause) : super(cause.message, cause.uri);

  @override
  String toString() => 'Could not reach the server. Check your connection and try again.';
}
