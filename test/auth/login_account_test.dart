import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/data/auth_api.dart';

/// DAS-105: the login and signup answers carry the account, so a sign-in
/// needs no second request for the business type. An older server, without
/// it, is asked as before.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

MockClient _server({required bool withAccount, required List<String> paths}) => MockClient((req) async {
      paths.add(req.url.path);
      return switch (req.url.path) {
        '/auth/login' || '/auth/signup' => _json({
            'access_token': _token,
            if (withAccount) 'account': {'tenant_name': 'Kirana Corner', 'email': 'k@x.in', 'business_type': 'kirana'},
          }),
        '/account' => _json({'tenant_name': 'Kirana Corner', 'email': 'k@x.in', 'business_type': 'kirana'}),
        _ => http.Response('not found', 404),
      };
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // platform channels (storage, path_provider)
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ApiClient.instance.token = null;
  });
  tearDown(() => ApiClient.instance.token = null);

  test('login with the account in the answer: one request, theme set from it', () async {
    final paths = <String>[];
    await http.runWithClient(() async {
      await ApiClient.instance.login(email: 'k@x.in', password: 'p');
    }, () => _server(withAccount: true, paths: paths));
    expect(paths, ['/auth/login']);
    expect(ApiClient.instance.businessTypeNotifier.value, 'kirana');
  });

  test('login on an older server: the account is fetched as before', () async {
    final paths = <String>[];
    await http.runWithClient(() async {
      await ApiClient.instance.login(email: 'k@x.in', password: 'p');
    }, () => _server(withAccount: false, paths: paths));
    expect(paths, ['/auth/login', '/account']);
    expect(ApiClient.instance.businessTypeNotifier.value, 'kirana');
  });

  test('signup takes the business type from the account when sent, else the one chosen', () async {
    final paths = <String>[];
    await http.runWithClient(() async {
      await ApiClient.instance.signup(tenantName: 'K', email: 'k@x.in', password: 'p', businessType: 'medical');
    }, () => _server(withAccount: true, paths: paths));
    expect(paths, ['/auth/signup']);
    expect(ApiClient.instance.businessTypeNotifier.value, 'kirana', reason: "the server's word wins");

    ApiClient.instance.token = null;
    await http.runWithClient(() async {
      await ApiClient.instance.signup(tenantName: 'K', email: 'k@x.in', password: 'p', businessType: 'medical');
    }, () => _server(withAccount: false, paths: paths));
    expect(ApiClient.instance.businessTypeNotifier.value, 'medical');
  });
}
