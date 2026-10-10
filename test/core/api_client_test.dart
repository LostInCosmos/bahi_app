import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';

/// The transport every request goes through: a timeout on every call, and a
/// refused token ending the session once, back at the login screen.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// What a call ended in: null for success, else what it threw.
Future<Object?> _outcome(Future<Object?> call) async {
  try {
    await call;
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  final api = ApiClient.instance;
  var ended = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'token': 'old.token.value'});
    api.token = 'old.token.value';
    ended = 0;
    api.onSessionEnded = () => ended++;
  });
  tearDown(() => api.onSessionEnded = null);

  test('a refused token signs this device out, once, however many requests were refused', () async {
    final client = MockClient((req) async => _json({'detail': 'token revoked'}, 401));
    await http.runWithClient(() async {
      final results = await Future.wait([
        _outcome(api.getAccount()),
        _outcome(api.listFolders()),
      ]);
      expect(results, everyElement(isA<ApiException>()), reason: 'each caller still hears it failed');
    }, () => client);

    expect(api.token, isNull);
    expect(api.isLoggedIn, isFalse);
    expect(ended, 1);
  });

  test('a wrong password at login is an error on the login screen, not a session ending', () async {
    api.token = null;
    final client = MockClient((req) async => _json({'detail': 'Invalid email or password'}, 401));
    await http.runWithClient(() async {
      await expectLater(api.login(email: 'a@b.c', password: 'x'), throwsA(isA<ApiException>()));
    }, () => client);
    expect(ended, 0);
  });

  test('a refusal for a session already replaced does not sign out the new one', () async {
    final answer = Completer<http.Response>();
    final client = MockClient((req) => answer.future);
    await http.runWithClient(() async {
      final inFlight = _outcome(api.getAccount());
      // Signed in again while that request was still out.
      api.token = 'new.token.value';
      answer.complete(_json({'detail': 'token revoked'}, 401));
      expect(await inFlight, isA<ApiException>());
    }, () => client);
    expect(api.token, 'new.token.value');
    expect(ended, 0);
  });

  test('other refusals leave the session alone', () async {
    final client = MockClient((req) async => _json({'detail': 'not found'}, 404));
    await http.runWithClient(() async {
      await expectLater(api.getInvoiceDetail(1), throwsA(isA<ApiException>()));
    }, () => client);
    expect(api.token, 'old.token.value');
    expect(ended, 0);
  });

  testWidgets('a server that stops answering times out instead of spinning for ever', (tester) async {
    final client = MockClient((req) => Completer<http.Response>().future);
    await http.runWithClient(() async {
      Object? error;
      api.getAccount().catchError((Object e) {
        error = e;
        return Future<Never>.error(e);
      }).ignore();
      await tester.pump(ApiClient.readTimeout - const Duration(seconds: 1));
      expect(error, isNull, reason: 'still within the timeout');
      await tester.pump(const Duration(seconds: 2));
      expect(error, isA<TimeoutException>());
    }, () => client);
  });
}
