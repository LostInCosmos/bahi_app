import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/main.dart';

/// Signed out on another device: this one used to keep every screen showing
/// its own error, with nothing leading back to the login screen.
void main() {
  testWidgets('a token the server refuses takes the app back to login, saying why', (tester) async {
    // The test font is wider than any real one; a row that fits on a phone
    // can overflow here, and that is not what this test is about.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    SharedPreferences.setMockInitialValues({});
    // A token whose payload names a shop, as a real one does.
    final payload = base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '');
    FlutterSecureStorage.setMockInitialValues({'token': 'h.$payload.s'});

    final client = MockClient((req) async => http.Response(
          jsonEncode({'detail': 'token revoked'}),
          401,
          headers: {'content-type': 'application/json'},
        ));
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }, () => client);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('You were signed out. Please log in again.'), findsOneWidget);
    expect(ApiClient.instance.isLoggedIn, isFalse);
  });
}
