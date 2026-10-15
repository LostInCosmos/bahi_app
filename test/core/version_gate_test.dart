import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/main.dart';

/// DAS-74: the app told it has fallen behind what the server wants, end to
/// end through the real startup flow (GstBillApp's own auto-refresh call on
/// launch is what carries the signal here, the same as session_ended_test).
void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Dastavez',
      packageName: 'com.dastavez.bahi',
      version: '1.0.0',
      buildNumber: '2002',
      buildSignature: '',
    );
  });
  tearDown(() => ApiClient.instance.onVersionGate = null);

  testWidgets('a soft minimum shows a dismissible banner, not a hard block', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final payload = base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '');
    FlutterSecureStorage.setMockInitialValues({'token': 'h.$payload.s'});

    final client = MockClient((req) async => http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json', 'x-min-app-build': '9999'},
        ));
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }, () => client);

    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('A new version of this app is available.'), findsOneWidget);
    // Not blocked: the home screen is still there underneath the banner.
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('a hard-block minimum replaces the screen, with a way to log out', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final payload = base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '');
    FlutterSecureStorage.setMockInitialValues({'token': 'h.$payload.s'});

    final client = MockClient((req) async => http.Response(
          '{}',
          200,
          headers: {
            'content-type': 'application/json',
            'x-min-app-build': '9999',
            'x-min-app-build-hard': '9999',
          },
        ));
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }, () => client);

    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('This app needs to be updated before it can be used. Please contact support.'),
        findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
  });
}
