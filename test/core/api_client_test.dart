import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/api/idempotency.dart';
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

  group('what a shopkeeper reads when a request fails', () {
    test("a proxy's HTML error page becomes 'Server error (502)', not the page", () async {
      final client = MockClient((req) async =>
          http.Response('<html><body><h1>502 Bad Gateway</h1></body></html>', 502, headers: {'content-type': 'text/html'}));
      await http.runWithClient(() async {
        final e = await _outcome(api.get('/invoices')) as ApiException;
        expect(e.statusCode, 502);
        expect('$e', 'Server error (502)');
      }, () => client);
    });

    test('a plain-text 4xx becomes a generic line, a JSON detail keeps its sentence and its field', () async {
      await http.runWithClient(() async {
        expect('${await _outcome(api.get('/a'))}', 'Request failed (404)');
      }, () => MockClient((req) async => http.Response('not found at all', 404)));
      await http.runWithClient(() async {
        final e = await _outcome(api.get('/a')) as ApiException;
        expect('$e', 'Enter a 10-digit phone number.');
        expect(e.field, 'buyer_phone');
      }, () => MockClient((req) async => _json({'detail': 'Enter a 10-digit phone number.', 'field': 'buyer_phone'}, 422)));
    });

    test('a structured detail stays inspectable, and its message is its sentence or the generic line', () async {
      await http.runWithClient(() async {
        final e = await _outcome(api.get('/a')) as ApiException;
        expect(e.errorCode, 'validation_failed');
        expect((e.detail as Map)['issues'], hasLength(1));
        expect('$e', 'Request failed (422)', reason: 'never the JSON blob');
      }, () => MockClient((req) async => _json({
            'detail': {'error': 'validation_failed', 'issues': [{'field': 'x'}]}
          }, 422)));
      await http.runWithClient(() async {
        expect('${await _outcome(api.get('/a'))}', 'That bill is being processed.');
      }, () => MockClient((req) async => _json({
            'detail': {'error': 'processing', 'message': 'That bill is being processed.'}
          }, 409)));
    });

    test('a timeout and a dropped connection read as plain sentences, and keep their types', () async {
      await http.runWithClient(() async {
        final e = await _outcome(api.get('/a', timeout: const Duration(milliseconds: 20)));
        expect(e, isA<TimeoutException>());
        expect('$e', 'The server took too long to answer. Try again.');
      }, () => MockClient((req) => Completer<http.Response>().future));
      await http.runWithClient(() async {
        final e = await _outcome(api.postJson('/a', {}));
        expect(e, isA<http.ClientException>());
        expect('$e', 'Could not reach the server. Check your connection and try again.');
      }, () => MockClient((req) async => throw http.ClientException('Connection reset by peer', req.url)));
    });
  });

  group('Idempotency-Key on a write (quality pass)', () {
    setUp(() => ApiClient.inProgressRetryDelay = const Duration(milliseconds: 10));
    tearDown(() => ApiClient.inProgressRetryDelay = const Duration(seconds: 2));

    test('the key is kept across a lost answer, and changes after an answer or a changed body', () async {
      final keys = <String?>[];
      var answer = 0; // 0: drop the connection, else that status
      final client = MockClient((req) async {
        keys.add(req.headers['Idempotency-Key']);
        if (answer == 0) throw http.ClientException('Connection reset by peer', req.url);
        return _json({'sale_id': 5}, answer);
      });
      final key = IdempotencyKey();
      await http.runWithClient(() async {
        expect(await _outcome(api.postJson('/sales', {'a': 1}, idempotency: key)), isA<http.ClientException>());
        expect(await _outcome(api.postJson('/sales', {'a': 1}, idempotency: key)), isA<http.ClientException>());
        expect(keys[1], keys[0], reason: 'the answer was lost: the same write, the same key');
        expect(keys[0], hasLength(32));

        await _outcome(api.postJson('/sales', {'a': 2}, idempotency: key));
        expect(keys[2], isNot(keys[0]), reason: 'a different body is a different write');

        answer = 422;
        await _outcome(api.postJson('/sales', {'a': 2}, idempotency: key));
        answer = 200;
        await api.postJson('/sales', {'a': 2}, idempotency: key);
        expect(keys[4], isNot(keys[3]), reason: 'a refusal is an answer: the next send is a new attempt');

        await api.postJson('/sales', {'a': 2}, idempotency: key);
        expect(keys[5], isNot(keys[4]), reason: 'the same sale sent again on purpose is a new sale');
      }, () => client);
      expect(await _outcome(http.runWithClient(() => api.postJson('/sales', {'a': 1}), () => client)), isNull);
      expect(keys.last, isNull, reason: 'no key asked for: no header');
    });

    test('409 in_progress is asked again with the same key until it is answered', () async {
      final keys = <String?>[];
      final client = MockClient((req) async {
        keys.add(req.headers['Idempotency-Key']);
        return keys.length < 3 ? _json({'error': 'in_progress'}, 409) : _json({'sale_id': 7});
      });
      await http.runWithClient(() async {
        final res = await api.postJson('/sales', {'a': 1}, idempotency: IdempotencyKey());
        expect(res.statusCode, 200);
      }, () => client);
      expect(keys, hasLength(3));
      expect(keys.toSet(), hasLength(1), reason: 'one key, three sends');
    });

    test('an upload keeps its key for the same file, and a timeout keeps it too', () async {
      final keys = <String?>[];
      var hang = true;
      final client = MockClient((req) {
        keys.add(req.headers['Idempotency-Key']);
        return hang ? Completer<http.Response>().future : Future.value(_json({'job_id': 9}));
      });
      final key = IdempotencyKey();
      Future<Object?> send() => _outcome(api.multipart('/invoices/extract', (r) {
            r.fields['source_image'] = 'a.jpg';
          }, timeout: const Duration(milliseconds: 20), idempotency: key, fingerprint: 'a.jpg'));
      await http.runWithClient(() async {
        expect(await send(), isA<TimeoutException>());
        hang = false;
        expect(await send(), isNull);
        expect(keys[1], keys[0]);
      }, () => client);
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
