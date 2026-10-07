import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/models/account.dart';
import '../../features/folders/models/folder.dart';
import '../../features/invoice/models/invoice.dart';
import '../../features/inventory/models/product.dart';
import '../../features/sales/models/sale.dart';
import '../../features/voice/models/voice.dart';
import '../utils/bill_image_cache.dart';
import 'api_exception.dart';

export 'api_exception.dart';

part '../../features/auth/data/auth_api.dart';
part '../../features/invoice/data/invoice_api.dart';
part '../../features/folders/data/folder_api.dart';
part '../../features/inventory/data/inventory_api.dart';
part '../../features/sales/data/sale_api.dart';
part '../../features/voice/data/voice_api.dart';

/// Minimal (x, y) pair — avoids pulling in dart:ui's Offset in a file that
/// otherwise has no Flutter widget dependency.
class Offset2D {
  final double x;
  final double y;
  const Offset2D(this.x, this.y);
}

/// True in any non-release build (debug/profile), where the server-address
/// field has always been shown — OR in a release build explicitly compiled
/// with `--dart-define=ALLOW_SERVER_OVERRIDE=true`. That second case is for
/// a real release-signed, release-performance build you sideload onto a
/// device to point at a local dev backend (e.g. exposed via `cloudflared
/// tunnel`) instead of production — never the default, and never set for
/// the actual production build. The real security boundary this exists to
/// protect (see login_screen.dart's docstring) is that a shopkeeper's
/// ordinary release build — built WITHOUT this flag — can't be talked into
/// pointing at an attacker's server.
const bool kAllowServerOverride = !kReleaseMode || bool.fromEnvironment('ALLOW_SERVER_OVERRIDE');

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

  static const _productionBaseUrl = "https://api.dastavez.co.in";
  String baseUrl = kReleaseMode ? _productionBaseUrl : "http://10.0.2.2:8000";
  String? token;

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Drives the app's color scheme (teal for medical, red for kirana — see
  /// theme.dart) — a [ValueNotifier] so the theme updates live the moment
  /// the account loads or changes, without needing a restart.
  final businessTypeNotifier = ValueNotifier<String>('medical');

  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    if (kAllowServerOverride) {
      baseUrl = prefs.getString('base_url') ?? baseUrl;
    }
    token = await _secureStorage.read(key: 'token');
    if (token == null) {
      final legacyToken = prefs.getString('token');
      if (legacyToken != null) {
        token = legacyToken;
        await _secureStorage.write(key: 'token', value: legacyToken);
        await prefs.remove('token');
      }
    }
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
    await _secureStorage.write(key: 'token', value: token);
  }

  Future<void> logout() async {
    if (token != null) {
      try {
        await http.post(_uri('/auth/logout'), headers: _authHeader);
      } catch (_) {
        // ignored — local logout still proceeds
      }
    }
    token = null;
    businessTypeNotifier.value = 'medical';
    await _secureStorage.delete(key: 'token');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('business_type');
  }

  bool get isLoggedIn => token != null;

  /// The signed-in shop, read from the JWT's own payload rather than fetched
  /// — on-device storage (the capture batch, pending photos, the image
  /// cache) is scoped by it and needs it before any request has been made.
  /// Not verified here; the server verifies the token on every request.
  int? get tenantId {
    final t = token;
    if (t == null) return null;
    try {
      final parts = t.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
      return payload['tenant_id'] as int?;
    } catch (_) {
      return null;
    }
  }

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
