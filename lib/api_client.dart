import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

part 'api/auth_api.dart';
part 'api/invoice_api.dart';
part 'api/inventory_api.dart';
part 'api/sale_api.dart';
part 'api/voice_api.dart';

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

/// Minimal (x, y) pair — avoids pulling in dart:ui's Offset in a file that
/// otherwise has no Flutter widget dependency.
class Offset2D {
  final double x;
  final double y;
  const Offset2D(this.x, this.y);
}

/// Thin REST client for the FastAPI backend. Holds the base URL and JWT in
/// memory plus SharedPreferences so both survive app restarts. The base URL
/// is user-editable from the login screen since "localhost" means different
/// things on an emulator (10.0.2.2), a physical device (the host's LAN IP),
/// and a desktop build.
///
/// The actual endpoint methods live in extensions on this class, split by
/// domain into api/*.dart (auth, invoices, inventory, sales, voice) via the
/// `part` directives above — they're still one library and one effective
/// class, so every call site keeps using `ApiClient.instance.someMethod()`
/// exactly as before regardless of which file someMethod is physically in.
/// This class itself holds only the shared transport plumbing every domain
/// needs (base URL/token state, the auth header, URI building, error
/// decoding).
class ApiClient {
  ApiClient._internal();
  static final ApiClient instance = ApiClient._internal();

  String baseUrl = "http://10.0.2.2:8000";
  String? token;

  /// Drives the app's color scheme (teal for medical, red for kirana — see
  /// theme.dart) — a [ValueNotifier] so the theme updates live the moment
  /// the account loads or changes, without needing a restart.
  final businessTypeNotifier = ValueNotifier<String>('medical');

  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('base_url') ?? baseUrl;
    token = prefs.getString('token');
    businessTypeNotifier.value = prefs.getString('business_type') ?? 'medical';
  }

  Future<void> _saveBusinessType(String type) async {
    businessTypeNotifier.value = type;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('business_type', type);
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base_url', url);
  }

  Future<void> _saveToken(String token) async {
    this.token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
  }

  Future<void> logout() async {
    token = null;
    businessTypeNotifier.value = 'medical';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('business_type');
  }

  bool get isLoggedIn => token != null;

  Map<String, String> get _authHeader => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  void _checkOk(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String message = res.body;
    dynamic detail;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'];
        message = detail is String ? detail : jsonEncode(detail);
      }
    } catch (_) {
      // response wasn't JSON — fall back to raw body
    }
    throw ApiException(res.statusCode, message, detail);
  }
}
