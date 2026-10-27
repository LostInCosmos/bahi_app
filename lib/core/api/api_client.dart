import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/business_types.dart';
import '../disk/bill_image_cache.dart';
import 'api_exception.dart';

export 'api_exception.dart';


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

/// How far behind this installed build is of what the server currently
/// wants (DAS-74). `nudge` is a dismissible "please update"; `hardBlock` is
/// a true breaking change, set separately and explicitly on the server —
/// never the default just from being behind.
enum VersionGateLevel { ok, nudge, hardBlock }

/// Thin REST client for the FastAPI backend. Holds the base URL and JWT in
/// memory plus SharedPreferences so both survive app restarts. The base URL
/// is user-editable from the login screen since "localhost" means different
/// things on an emulator (10.0.2.2), a physical device (the host's LAN IP),
/// and a desktop build.
///
/// The endpoint methods live in each feature's own `data/<feature>_api.dart`,
/// as an `extension` on this class — a caller imports that file and keeps
/// writing `ApiClient.instance.someMethod()`. This class holds only the
/// shared transport every feature needs (base URL and token state, the auth
/// header, timeouts, error decoding) and knows nothing about any feature:
/// core imports no feature, so adding one never edits this file (DAS-86).
///
/// The request helpers ([get], [postJson], …) are public so those extensions
/// can live in their own libraries. Every one still goes through [_send],
/// which stays private — so every request keeps its auth header, timeout,
/// version check and 401 handling. Call the server through them, never
/// through `http.*` directly.
class ApiClient {
  ApiClient._internal();
  static final ApiClient instance = ApiClient._internal();

  static const _productionBaseUrl = "https://api.dastavez.co.in";
  String baseUrl = kReleaseMode ? _productionBaseUrl : "http://10.0.2.2:8000";
  String? token;

  /// Where the login token lives. On iOS the Keychain item is kept to THIS
  /// device (DAS-135): the token never expires, and the default class lets an
  /// iCloud or iTunes backup restore it onto a new iPhone, signed in with no
  /// password. A reinstall on the same device still keeps it.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
  );

  /// How builds before DAS-135 stored it on iOS (the plugin's default class).
  /// The plugin matches on the class when reading, so a token written that way
  /// is only found with these options; it is read once and written again
  /// under [_secureStorage], which moves it to the this-device class.
  static const _legacySecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// The stored token, or null. Never throws: a Keychain or Keystore that
  /// cannot be read (some devices refuse right after boot; a restored backup
  /// cannot unwrap its key) means "signed out", and the login screen is the
  /// way back — not a crash at launch (DAS-135).
  Future<String?> _readStoredToken() async {
    try {
      final current = await _secureStorage.read(key: 'token');
      if (current != null) return current;
      if (!Platform.isIOS) return null;
      final legacy = await _legacySecureStorage.read(key: 'token');
      if (legacy != null) await _secureStorage.write(key: 'token', value: legacy);
      return legacy;
    } catch (_) {
      return null;
    }
  }

  /// Drives the app's color scheme (teal for medical, red for kirana — see
  /// theme.dart) — a [ValueNotifier] so the theme updates live the moment
  /// the account loads or changes, without needing a restart.
  final businessTypeNotifier = ValueNotifier<String>(kDefaultBusinessType);

  /// Whether this shop may use voice (DAS-112). The admin switches it per
  /// shop; the server says so on every authenticated response
  /// (`X-Voice-Enabled: 1|0`) and in the login and account answers. True until
  /// told otherwise, so an older server never hides voice by accident, and
  /// kept per shop on the device so a restart does not flash the mic on.
  final voiceEnabledNotifier = ValueNotifier<bool>(true);

  static String _voiceKey(int shop) => 'voice_enabled_$shop';

  /// Records what the server said about voice for the signed-in shop.
  Future<void> setVoiceEnabled(bool enabled) async {
    if (voiceEnabledNotifier.value == enabled) return;
    voiceEnabledNotifier.value = enabled;
    final shop = tenantId;
    if (shop == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_voiceKey(shop), enabled);
    } catch (_) {
      // Held in memory regardless; the next response says it again.
    }
  }

  /// The switch as this device last knew it for [shop]; true when never told.
  Future<void> _loadVoiceEnabled(int? shop) async {
    if (shop == null) {
      voiceEnabledNotifier.value = true;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    voiceEnabledNotifier.value = prefs.getBool(_voiceKey(shop)) ?? true;
  }

  /// A response to a request that carried the shop's token says whether voice
  /// is on. No header (an older server, a route that does not load the shop)
  /// means no change, never off.
  void _applyVoiceSwitch(http.Response res) {
    final switchValue = res.headers['x-voice-enabled'];
    if (switchValue == '1') unawaited(setVoiceEnabled(true));
    if (switchValue == '0') unawaited(setVoiceEnabled(false));
  }

  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    if (kAllowServerOverride) {
      baseUrl = prefs.getString('base_url') ?? baseUrl;
    }
    token = await _readStoredToken();
    if (token == null) {
      final legacyToken = prefs.getString('token');
      if (legacyToken != null) {
        token = legacyToken;
        try {
          await _secureStorage.write(key: 'token', value: legacyToken);
          await prefs.remove('token');
        } catch (_) {
          // Kept in shared_preferences until a write succeeds; signed in now.
        }
      }
    }
    businessTypeNotifier.value = prefs.getString('business_type') ?? kDefaultBusinessType;
    await _loadVoiceEnabled(tenantId);
  }

  int _appBuild = 0;
  String _appPlatform = 'other';

  /// This installed build's own number and platform, read once at startup
  /// and sent with every request from here on (DAS-74) so the server can
  /// tell an old build apart from a current one. Awaited alongside
  /// [loadFromDisk], before the first screen shows.
  Future<void> loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      // A build number of 0 never trips a minimum — fails open, same as the
      // server's own cache does on its side.
    }
    _appPlatform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other');
  }

  Future<void> saveBusinessType(String type) async {
    businessTypeNotifier.value = type;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('business_type', type);
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base_url', url);
  }

  /// Public only so the auth feature's login and signup can call it. The
  /// server checks every token, so a bad one costs a 401 and a sign-out.
  /// Drops any other shop's cached bill photos (DAS-90), in the background:
  /// signing in never waits on cache housekeeping, and the new shop only ever
  /// writes and reads files of its own, so nothing it does races the delete.
  Future<void> saveToken(String token) async {
    this.token = token;
    await _secureStorage.write(key: 'token', value: token);
    final shop = tenantId;
    if (shop != null) unawaited(BillImageCache.keepOnlyShop(shop));
    await _loadVoiceEnabled(shop);
  }

  /// Called when the server refuses this device's token — signed out from
  /// another device, or the password changed. Set by the app, which takes the
  /// shopkeeper back to the login screen; every screen used to show its own
  /// error instead, for ever, with nothing leading out of it.
  VoidCallback? onSessionEnded;

  Future<void> logout() async {
    final sent = token;
    if (sent != null) {
      try {
        // Not through _send: this is already ending the session, and a 401
        // (revoked elsewhere) must not end it a second time.
        await http
            .post(_uri('/auth/logout'), headers: {'Authorization': 'Bearer $sent'})
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // ignored — local logout still proceeds
      }
    }
    await _forget();
  }

  /// Drops the token and the shop's theme from this device. The capture
  /// batch, pending photos and image cache are kept, per shop, for the next
  /// sign-in (see BatchStore).
  Future<void> _forget() async {
    token = null;
    businessTypeNotifier.value = kDefaultBusinessType;
    voiceEnabledNotifier.value = true;
    try {
      await _secureStorage.delete(key: 'token');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('business_type');
    } catch (_) {
      // Signed out in memory regardless. A token left on disk is refused on
      // its first request after a restart, which ends that session too.
    }
  }

  /// [sent] is the token the refused request carried. A request still in
  /// flight from a session that has since been replaced must not sign out the
  /// new one, and a burst of refusals ends the session once.
  Future<void> _sessionRefused(String sent) async {
    if (token != sent) return;
    await _forget();
    onSessionEnded?.call();
  }

  /// What the server's last response said about this build (DAS-74).
  VersionGateLevel get versionGate => _versionGate;
  VersionGateLevel _versionGate = VersionGateLevel.ok;
  VersionGateLevel _lastNotifiedVersionGate = VersionGateLevel.ok;

  /// Fires on an actual change of [versionGate], not on every request — a
  /// dismissed nudge must not reappear just because another request landed,
  /// and one flaky response must not flicker the UI. Set by the app.
  void Function(VersionGateLevel level)? onVersionGate;

  /// Read independently of the 401 check below: an outdated build is told
  /// to update even hitting /auth/login unauthenticated. Checked after the
  /// 401 so that if both fire on the same response, the version gate's own
  /// navigation (more useful than "log in again" to a build that will not
  /// work once logged in) is the one left on screen.
  void _applyVersionGate(http.Response res) {
    final minBuild = int.tryParse(res.headers['x-min-app-build'] ?? '');
    final hardBuild = int.tryParse(res.headers['x-min-app-build-hard'] ?? '');
    final level = hardBuild != null && _appBuild < hardBuild
        ? VersionGateLevel.hardBlock
        : minBuild != null && _appBuild < minBuild
            ? VersionGateLevel.nudge
            : VersionGateLevel.ok;
    _versionGate = level;
    if (level == _lastNotifiedVersionGate) return;
    _lastNotifiedVersionGate = level;
    onVersionGate?.call(level);
  }

  bool get isLoggedIn => token != null;

  /// The signed-in shop, read from the JWT's own payload rather than fetched
  /// — on-device storage (the capture batch, pending photos, the image cache)
  /// is scoped by it and needs it before any request has been made.
  /// Not verified here; the server verifies the token on every request.
  ///
  /// Decoded once per token, not per call: every thumbnail, every batch save
  /// and every pending-photo write asks, and base64-decoding a JWT each time
  /// was measurable on a 300-card grid.
  int? get tenantId {
    final t = token;
    if (t == null) return null;
    if (t == _tenantIdToken) return _tenantIdCached;
    _tenantIdToken = t;
    return _tenantIdCached = _decodeTenantId(t);
  }

  String? _tenantIdToken;
  int? _tenantIdCached;

  static int? _decodeTenantId(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
      return (payload['tenant_id'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// One connection pool for the life of the app. The top-level `http.get`
  /// and friends open a fresh connection per call, so every request — each
  /// thumbnail included — paid a TLS handshake (~0.2 s measured from a
  /// laptop, more on cellular). A single `Client` keeps connections alive.
  ///
  /// Made with the `http.Client()` factory, which honours
  /// `http.runWithClient`, and remade whenever the zone changes: a test's
  /// `runWithClient` runs in its own zone and must never be answered by the
  /// client a previous test created. In the app the zone never changes.
  ///
  /// The old client is dropped, not closed (DAS-119): `IOClient.close()` is a
  /// forced close that aborts every request still in flight. The end-to-end
  /// harness runs the app's code in more than one zone, and each switch used
  /// to kill whatever was loading ("Connection closed before full header was
  /// received"). A dropped client's idle connections time out by themselves.
  http.Client get _http {
    final zone = Zone.current;
    if (_client == null || _clientZone != zone) {
      _client = http.Client();
      _clientZone = zone;
    }
    return _client!;
  }

  http.Client? _client;
  Zone? _clientZone;

  // ---- transport ----
  //
  // Every call goes through [_send], so every call has a timeout and every
  // refusal is read the same way. Without one, a request to a server that
  // stopped answering waited on the phone's own socket timeouts — minutes,
  // behind a spinner.

  /// An ordinary request: a JSON read or write.
  static const readTimeout = Duration(seconds: 30);

  /// A request the server does real work in before answering — validating a
  /// bill, searching its suppliers.
  static const workTimeout = Duration(seconds: 60);

  /// A photo or recording going up, or a file coming down, on a shop's
  /// mobile connection.
  static const transferTimeout = Duration(seconds: 120);

  /// A request the server holds open until something changes (~25s). Past
  /// this it is a dead connection, not a slow one.
  static const heldTimeout = Duration(seconds: 40);

  /// Sends [request] with the auth header (unless [auth] is false: signing
  /// in has no token to send) and a JSON content type when [json]. Throws
  /// [ApiException] for a non-2xx answer and `TimeoutException` past
  /// [timeout]. A 401 to a request that carried a token ends the session.
  ///
  /// An [idempotent] request whose connection fails before any answer is sent
  /// once more (DAS-119): a pooled connection the network or server has
  /// already closed fails the first time it is reused, and asking again opens
  /// a fresh one. Only reads: a write that failed this way may still have been
  /// done, and is never sent twice. A timeout is not retried — the server may
  /// be working, and a second wait doubles the spinner.
  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) request, {
    bool auth = true,
    bool json = false,
    Duration timeout = readTimeout,
    Map<String, String>? headers,
    bool notModifiedOk = false,
    bool idempotent = false,
  }) async {
    final sent = auth ? token : null;
    final sendHeaders = {
      if (sent != null) 'Authorization': 'Bearer $sent',
      if (json) 'Content-Type': 'application/json',
      'X-App-Build': '$_appBuild',
      'X-App-Platform': _appPlatform,
      ...?headers,
    };
    http.Response res;
    try {
      res = await request(sendHeaders).timeout(timeout);
    } on http.ClientException {
      if (!idempotent) rethrow;
      res = await request(sendHeaders).timeout(timeout);
    }
    if (res.statusCode == 401 && sent != null) await _sessionRefused(sent);
    _applyVersionGate(res);
    if (sent != null && token == sent) _applyVoiceSwitch(res);
    // A 304 to a conditional GET is "what you hold is current", not a failure.
    if (!(notModifiedOk && res.statusCode == 304)) _checkOk(res);
    return res;
  }

  /// [ifNoneMatch] makes it a conditional GET: an `ETag` the caller kept
  /// from the last answer. The server may then answer `304` with no body,
  /// which is returned as-is (status 304, empty body) for the caller to read
  /// as "unchanged". A server without ETags ignores the header.
  Future<http.Response> get(
    String path, {
    Map<String, String>? query,
    Duration timeout = readTimeout,
    String? ifNoneMatch,
  }) =>
      _send(
        (h) => _http.get(_uri(path, query), headers: h),
        timeout: timeout,
        headers: ifNoneMatch == null ? null : {'If-None-Match': ifNoneMatch},
        notModifiedOk: ifNoneMatch != null,
        idempotent: true,
      );

  Future<http.Response> post(String path, {Duration timeout = readTimeout}) =>
      _send((h) => _http.post(_uri(path), headers: h), timeout: timeout);

  Future<http.Response> postJson(String path, Object body, {bool auth = true, Duration timeout = readTimeout}) =>
      _send((h) => _http.post(_uri(path), headers: h, body: jsonEncode(body)), auth: auth, json: true, timeout: timeout);

  Future<http.Response> patchJson(String path, Object body) =>
      _send((h) => _http.patch(_uri(path), headers: h, body: jsonEncode(body)), json: true);

  Future<http.Response> delete(String path) => _send((h) => _http.delete(_uri(path), headers: h));

  /// A multipart form, built by [build] — photos and recordings.
  Future<http.Response> multipart(
    String path,
    FutureOr<void> Function(http.MultipartRequest request) build, {
    Map<String, String>? query,
    Duration timeout = transferTimeout,
  }) =>
      _send((h) async {
        final request = http.MultipartRequest('POST', _uri(path, query))..headers.addAll(h);
        await build(request);
        // Through the shared client: `request.send()` would open its own.
        return http.Response.fromStream(await _http.send(request));
      }, timeout: timeout);

  /// The date filter purchases and sales share, keeping only the ends that are set.
  static Map<String, String> dateRange(String? startDate, String? endDate) => {
        if (startDate != null) 'start_date': startDate,
        if (endDate != null) 'end_date': endDate,
      };

  /// The message to show for the current [versionGate] level (DAS-74),
  /// fetched only when there is one to show — never on the happy path. No
  /// store listing exists: distribution is USB-connect install only, so
  /// this is plain text ("ask the shop owner to reconnect and update"),
  /// never a tappable link.
  Future<String?> versionInfo() async {
    final res = await get('/app/version-info', query: {'platform': _appPlatform});
    return jsonObject(res)['message'] as String?;
  }

  static Map<String, dynamic> jsonObject(http.Response res) => jsonDecode(res.body) as Map<String, dynamic>;
  static List<dynamic> jsonList(http.Response res) => jsonDecode(res.body) as List<dynamic>;

  /// A JSON array of objects, each read with [fromJson] — what most list
  /// endpoints answer with. (Spelled out rather than through `core/utils/json`,
  /// so `core/api` and `core/utils` do not import each other: `poll.dart`
  /// already needs `ApiException`.)
  static List<T> listOf<T>(http.Response res, T Function(Map<String, dynamic>) fromJson) =>
      [for (final e in jsonList(res)) fromJson(e as Map<String, dynamic>)];

  void _checkOk(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String message = res.body;
    dynamic detail;
    String? field;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['field'] is String) field = decoded['field'] as String;
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'];
        message = detail is String ? detail : jsonEncode(detail);
      } else if (decoded is Map && decoded['error'] is String) {
        // `{"error": "account_deleted", "message": "…"}` — the shape the
        // login refusal for a deleted account uses. The whole map is the
        // detail, so `ApiException.errorCode` reads it the same way.
        detail = decoded;
        message = decoded['message'] is String ? decoded['message'] as String : decoded['error'] as String;
      }
    } catch (_) {
      // response wasn't JSON — fall back to raw body
    }
    throw ApiException(res.statusCode, message, detail, field);
  }
}
