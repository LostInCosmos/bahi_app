import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/config/legal_documents.dart';
import 'package:gst_bill_app/core/navigation/app_routes.dart';
import 'package:gst_bill_app/features/auth/models/account.dart';
import 'package:gst_bill_app/features/auth/presentation/legal_acceptance_screen.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';

/// DAS-104: the server records which legal version a shop accepted; when the
/// documents change, the app asks again before going on. The server never
/// enforces it, so old builds keep working.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _account({Map<String, dynamic>? legal}) => {
      'tenant_name': 'Shop',
      'email': 'o@x.in',
      'business_type': 'medical',
      if (legal != null) 'legal': legal,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ApiClient.instance.token = null;
  });
  tearDown(() => ApiClient.instance.token = null);

  group('AccountInfo.needsLegalAcceptance — the phone rule', () {
    AccountInfo of(Map<String, dynamic>? legal) => AccountInfo.fromJson(_account(legal: legal));

    test('asks when the server requires it and this build has the current text', () {
      expect(of({'current_version': kLegalVersion, 'accepted_version': '1.0', 'requires_acceptance': true}).needsLegalAcceptance,
          isTrue);
      expect(of({'current_version': '1.0', 'accepted_version': null, 'requires_acceptance': true}).needsLegalAcceptance,
          isTrue, reason: "the build's text is newer than the server's current: still shown, recorded as the build's");
    });

    test('asks nothing when accepted, when the server is older than the field, or when this build cannot show the text', () {
      expect(of({'current_version': kLegalVersion, 'accepted_version': kLegalVersion, 'requires_acceptance': false})
          .needsLegalAcceptance, isFalse);
      expect(of(null).needsLegalAcceptance, isFalse, reason: 'older server: no legal object');
      expect(of({'current_version': '9.0', 'accepted_version': '1.0', 'requires_acceptance': true}).needsLegalAcceptance,
          isFalse, reason: 'the server wants 9.0; this build carries $kLegalVersion and cannot show it');
    });
  });

  testWidgets('login: the documents changed → acceptance screen, Accept records the version, then home', (tester) async {
    final posts = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      switch (req.url.path) {
        case '/auth/login':
          return _json({
            'access_token': _token,
            'account': _account(legal: {'current_version': kLegalVersion, 'accepted_version': '1.0', 'requires_acceptance': true}),
          });
        case '/account/accept-legal':
          posts.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: const LoginScreen(),
        routes: {AppRoutes.home: (_) => const Scaffold(body: Text('HOME'))},
      ));
      await tester.enterText(find.byType(TextField).at(0), 'o@x.in');
      await tester.enterText(find.byType(TextField).at(1), 'pw');
      final login = find.widgetWithText(FilledButton, 'Log in');
      await tester.ensureVisible(login);
      await tester.tap(login);
      await tester.pumpAndSettle();

      expect(find.byType(LegalAcceptanceScreen), findsOneWidget);
      expect(find.text("We've updated our terms"), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      final accept = find.byKey(const ValueKey('accept-legal'));
      expect(tester.widget<FilledButton>(find.descendant(of: accept, matching: find.byType(FilledButton))).onPressed,
          isNull, reason: 'disabled until ticked');

      await tester.ensureVisible(find.byKey(const ValueKey('accept-legal-tick')));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('accept-legal-tick')), matching: find.byType(Checkbox)));
      await tester.pump();
      await tester.ensureVisible(accept);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(posts, [{'version': kLegalVersion}]);
      expect(find.text('HOME'), findsOneWidget);
    }, () => client);
  });

  testWidgets('login: already accepted → straight home', (tester) async {
    final client = MockClient((req) async {
      switch (req.url.path) {
        case '/auth/login':
          return _json({
            'access_token': _token,
            'account': _account(legal: {'current_version': kLegalVersion, 'accepted_version': kLegalVersion, 'requires_acceptance': false}),
          });
      }
      return http.Response('not found', 404);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: const LoginScreen(),
        routes: {AppRoutes.home: (_) => const Scaffold(body: Text('HOME'))},
      ));
      await tester.enterText(find.byType(TextField).at(0), 'o@x.in');
      await tester.enterText(find.byType(TextField).at(1), 'pw');
      final login = find.widgetWithText(FilledButton, 'Log in');
      await tester.ensureVisible(login);
      await tester.tap(login);
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      expect(find.byType(LegalAcceptanceScreen), findsNothing);
    }, () => client);
  });

  testWidgets('signup sends the version it showed', (tester) async {
    Map<String, dynamic>? signupBody;
    final client = MockClient((req) async {
      if (req.url.path == '/auth/signup') {
        signupBody = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({'access_token': _token, 'account': _account()});
      }
      return http.Response('not found', 404);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: const LoginScreen(),
        routes: {AppRoutes.home: (_) => const Scaffold(body: Text('HOME'))},
      ));
      await tester.tap(find.text('Sign up'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'My Shop');
      await tester.enterText(find.byType(TextField).at(1), 'o@x.in');
      await tester.enterText(find.byType(TextField).at(2), 'pw');
      await tester.ensureVisible(find.byKey(const ValueKey('accept-terms')));
      await tester.tap(find.byKey(const ValueKey('accept-terms')));
      await tester.pump();
      final create = find.widgetWithText(FilledButton, 'Create account');
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(signupBody?['legal_version'], kLegalVersion);
      expect(find.text('HOME'), findsOneWidget);
    }, () => client);
  });

  testWidgets('the acceptance screen: a failed record shows why and stays; Back does not skip it', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: LegalAcceptanceScreen(onAccept: (_) async {
        calls++;
        throw ApiException(500, 'server down');
      }),
    ));
    await tester.ensureVisible(find.byKey(const ValueKey('accept-legal-tick')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('accept-legal-tick')), matching: find.byType(Checkbox)));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('accept-legal')));
    await tester.tap(find.byKey(const ValueKey('accept-legal')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('server down'), findsOneWidget);
    expect(find.byType(LegalAcceptanceScreen), findsOneWidget);
    // Back is swallowed.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LegalAcceptanceScreen), findsOneWidget);
  });
}
