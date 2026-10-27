import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/presentation/account_screen.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';

/// In-app account deletion (R1 of the 2026-10-19 audit; Play's account
/// deletion policy and Apple 5.1.1(v)): password-confirmed, a wrong password
/// asks again without ending the session, and a deleted account is refused
/// at login with its own message.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Server {
  final deletes = <String>[];
  bool deleted = false;

  MockClient get client => MockClient((req) async {
        if (req.url.path == '/account' && req.method == 'GET') {
          return _json({'tenant_name': 'Shop', 'email': 'o@x.in', 'business_type': 'medical'}, 200);
        }
        if (req.url.path == '/account/delete') {
          final password = (jsonDecode(req.body) as Map)['password'] as String;
          deletes.add(password);
          if (password != 'right') return _json({'detail': {'error': 'wrong_password'}}, 403);
          deleted = true;
          return http.Response('', 204);
        }
        if (req.url.path == '/auth/logout') return http.Response('', 204);
        if (req.url.path == '/auth/login') {
          if (deleted) {
            return _json({'error': 'account_deleted', 'message': 'This account was deleted and its data is being removed.'}, 403);
          }
          return _json({'detail': 'Invalid email or password'}, 401);
        }
        return http.Response('not found', 404);
      });
}

void main() {
  late Directory root;
  setUpAll(() {
    // path_provider is answered here: the shop's local files live under it.
    root = Directory.systemTemp.createTempSync('account_deletion_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    SharedPreferences.setMockInitialValues({'bahi_batch_8': '[]', 'bahi_batch_9': '[]'});
    ApiClient.instance.token = _token;
  });
  tearDown(() => ApiClient.instance.token = null);

  /// A file of shop 8's and one of shop 9's in each on-device store.
  Future<List<File>> seedShopFiles() async {
    final files = <File>[];
    for (final folder in ['pending_photos', 'bill_images']) {
      for (final shop in [8, 9]) {
        final f = File('${root.path}/$folder/${shop}_bill.jpg');
        await f.create(recursive: true);
        files.add(f);
      }
    }
    return files;
  }

  testWidgets('Delete account: wrong password asks again; the right one signs the device out', (tester) async {
    final server = _Server();
    // Real file IO inside a widget test completes only under runAsync.
    final files = (await tester.runAsync(seedShopFiles))!;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: AccountScreen()));
      await tester.pumpAndSettle();

      // The body is a lazy list: scroll until the button is built.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('delete-account')), 200, scrollable: find.byType(Scrollable).first);
      // Built is not wholly on screen: bring all of it in before tapping.
      await tester.ensureVisible(find.byKey(const ValueKey('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-account')));
      await tester.pumpAndSettle();
      expect(find.text('Delete this account?'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('delete-confirm'))).onPressed, isNull,
          reason: 'nothing typed yet');

      await tester.enterText(find.byKey(const ValueKey('delete-password')), 'wrong');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Wrong password. Try again.'), findsOneWidget);
      expect(find.text('Delete this account?'), findsOneWidget, reason: 'still asking');
      expect(ApiClient.instance.token, _token, reason: 'a wrong password is not a refused token');

      await tester.enterText(find.byKey(const ValueKey('delete-password')), 'right');
      await tester.pump();
      // The wipe deletes real files, so this part runs under runAsync.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('delete-confirm')));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(server.deletes, ['wrong', 'right']);
      expect(find.text('Delete this account?'), findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(ApiClient.instance.token, isNull);
      // Shop 8's files are gone from both stores; shop 9's stay.
      for (final f in files) {
        expect(f.existsSync(), f.path.contains('/9_'), reason: f.path);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bahi_batch_8'), isNull);
      expect(prefs.getString('bahi_batch_9'), '[]');
    }, () => server.client);
  });

  testWidgets('a deleted account is told so at login, not "wrong password"', (tester) async {
    final server = _Server()..deleted = true;
    ApiClient.instance.token = null;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.enterText(find.byType(TextField).at(0), 'o@x.in');
      await tester.enterText(find.byType(TextField).at(1), 'right');
      final button = find.widgetWithText(FilledButton, 'Log in');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.textContaining('This account was deleted'), findsOneWidget);
    }, () => server.client);
  });

  test('ApiException reads {"error", "message"} as well as {"detail": {...}}', () async {
    final client = MockClient((req) async => _json({'error': 'account_deleted', 'message': 'gone'}, 403));
    await http.runWithClient(() async {
      try {
        await ApiClient.instance.get('/x');
        fail('expected a refusal');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.errorCode, 'account_deleted');
        expect(e.toString(), 'gone');
      }
    }, () => client);
  });
}
