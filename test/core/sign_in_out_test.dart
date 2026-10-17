import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/main.dart';

// DAS-86 broke the login <-> home import cycle: login reaches home by a named
// route, and both voluntary sign-outs share `signOut`. Neither navigation had
// a test, so these pin that the screens still land where they did — with
// nothing behind them to go Back to.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/auth/login' => {'access_token': _token},
    '/account' => {'tenant_name': 'Test Medical', 'email': 'shop@example.com'},
    _ => <String, dynamic>{},
  };
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
});

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _canGoBack(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first).canPop();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Dastavez',
      packageName: 'com.dastavez.bahi',
      version: '1.0.0',
      buildNumber: '2002',
      buildSignature: '',
    );
  });

  void ignoreOverflow() {
    // The test font is wider than any real one; that is not what these test.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  testWidgets('logging in lands on home, with the login screen gone', (tester) async {
    ignoreOverflow();
    FlutterSecureStorage.setMockInitialValues({});

    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      await _settle(tester);
      expect(find.byType(LoginScreen), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'shop@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await _settle(tester);
    }, () => _server);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(_canGoBack(tester), isFalse, reason: 'login was replaced, not covered');
  });

  testWidgets('logging out lands on login, with nothing behind it', (tester) async {
    ignoreOverflow();
    FlutterSecureStorage.setMockInitialValues({'token': _token});

    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      await _settle(tester);
      expect(find.byType(HomeScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Log out'));
      await _settle(tester);
    }, () => _server);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(_canGoBack(tester), isFalse, reason: 'Back must not reach a signed-out home');
    expect(ApiClient.instance.isLoggedIn, isFalse);
  });
}
