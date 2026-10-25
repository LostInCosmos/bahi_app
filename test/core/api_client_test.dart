import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/data/auth_api.dart';
import 'package:gst_bill_app/features/folders/data/folder_api.dart';
import 'package:gst_bill_app/features/invoice/data/invoice_api.dart';

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

http.Response _ok(Map<String, String> extraHeaders) =>
    http.Response('{}', 200, headers: {'content-type': 'application/json', ...extraHeaders});

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

  group('version gate (DAS-74)', () {
    setUp(() async {
      PackageInfo.setMockInitialValues(
        appName: 'Dastavez',
        packageName: 'com.dastavez.bahi',
        version: '1.0.0',
        buildNumber: '2002',
        buildSignature: '',
      );
      await api.loadAppInfo();
      // ApiClient is a singleton, so the version gate left over from whatever
      // ran before this test in the same process must not leak in — put it
      // back at a known baseline (ok, not yet notified) via a real response.
      final baseline = MockClient((req) async => _ok({}));
      await http.runWithClient(() => _outcome(api.getAccount()), () => baseline);
    });
    tearDown(() => api.onVersionGate = null);

    test('sends its own build and platform on every request', () async {
      http.Request? seen;
      final client = MockClient((req) async {
        seen = req;
        return _ok({});
      });
      await http.runWithClient(() => _outcome(api.getAccount()), () => client);
      expect(seen?.headers['X-App-Build'], '2002');
      expect(seen?.headers['X-App-Platform'], isNotEmpty);
    });

    test('no minimum header means ok, and the callback never fires', () async {
      var calls = 0;
      api.onVersionGate = (_) => calls++;
      final client = MockClient((req) async => _ok({}));
      await http.runWithClient(() => _outcome(api.getAccount()), () => client);
      expect(api.versionGate, VersionGateLevel.ok);
      expect(calls, 0);
    });

    test('a build below the minimum is a dismissible nudge', () async {
      VersionGateLevel? seen;
      api.onVersionGate = (l) => seen = l;
      final client = MockClient((req) async => _ok({'x-min-app-build': '9999'}));
      await http.runWithClient(() => _outcome(api.getAccount()), () => client);
      expect(api.versionGate, VersionGateLevel.nudge);
      expect(seen, VersionGateLevel.nudge);
    });

    test('a build below the hard-block threshold blocks, even while also below the soft minimum', () async {
      final client = MockClient(
        (req) async => _ok({'x-min-app-build': '2100', 'x-min-app-build-hard': '9999'}),
      );
      await http.runWithClient(() => _outcome(api.getAccount()), () => client);
      expect(api.versionGate, VersionGateLevel.hardBlock);
    });

    test('the same level is not re-notified on a second request', () async {
      var calls = 0;
      api.onVersionGate = (_) => calls++;
      final client = MockClient((req) async => _ok({'x-min-app-build': '9999'}));
      await http.runWithClient(() async {
        await _outcome(api.getAccount());
        await _outcome(api.getAccount());
      }, () => client);
      expect(calls, 1);
    });

    test('recovering to a current-enough response notifies ok after a nudge', () async {
      final levels = <VersionGateLevel>[];
      api.onVersionGate = levels.add;
      var first = true;
      final client = MockClient((req) async {
        final res = _ok(first ? {'x-min-app-build': '9999'} : {});
        first = false;
        return res;
      });
      await http.runWithClient(() async {
        await _outcome(api.getAccount());
        await _outcome(api.getAccount());
      }, () => client);
      expect(levels, [VersionGateLevel.nudge, VersionGateLevel.ok]);
    });
  });

  group('a connection that drops before any answer (DAS-119)', () {
    test('a read is asked once more, and the second answer is used', () async {
      var calls = 0;
      final client = MockClient((req) async {
        if (++calls == 1) throw http.ClientException('Connection closed before full header was received', req.url);
        return _json({'ok': true});
      });
      await http.runWithClient(() async {
        final res = await api.get('/invoices');
        expect(res.statusCode, 200);
      }, () => client);
      expect(calls, 2);
    });

    test('a read that drops twice fails, after exactly one retry', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        throw http.ClientException('Connection attempt cancelled', req.url);
      });
      await http.runWithClient(() async {
        expect(await _outcome(api.get('/invoices')), isA<http.ClientException>());
      }, () => client);
      expect(calls, 2);
    });

    test('a write is never sent twice: it may already have been done', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        throw http.ClientException('Connection closed before full header was received', req.url);
      });
      await http.runWithClient(() async {
        expect(await _outcome(api.postJson('/invoices', {'a': 1})), isA<http.ClientException>());
        expect(await _outcome(api.delete('/invoices/1')), isA<http.ClientException>());
      }, () => client);
      expect(calls, 2, reason: 'one each, no retry');
    });

    test('an answer the server gave, even a refusal, is not asked again', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return _json({'detail': 'no'}, 404);
      });
      await http.runWithClient(() async {
        expect(await _outcome(api.get('/invoices/9')), isA<ApiException>());
      }, () => client);
      expect(calls, 1);
    });

    test('a request in another zone does not abort one still loading', () async {
      // The end-to-end harness runs app code in more than one zone. The shared
      // client is remade per zone, and closing the old one used to kill
      // whatever it was still loading.
      final slow = _ClosableClient();
      final loading = http.runWithClient(() => api.get('/invoices'), () => slow);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await http.runWithClient(() => api.get('/folders'), () => MockClient((_) async => _json([])));
      slow.answer.complete();
      expect((await loading).statusCode, 200);
      expect(slow.closed, isFalse);
    });
  });
}

/// A client whose requests wait for [answer], and fail if it was closed
/// meanwhile, the way `IOClient.close()` aborts what is in flight.
class _ClosableClient extends http.BaseClient {
  final answer = Completer<void>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await answer.future;
    if (closed) throw http.ClientException('Connection closed before full header was received', request.url);
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200, headers: {'content-type': 'application/json'});
  }

  @override
  void close() => closed = true;
}
