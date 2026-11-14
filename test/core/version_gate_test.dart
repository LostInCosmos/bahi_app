import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/utils/play_store.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/main.dart';

/// DAS-74: the app told it has fallen behind what the server wants, end to
/// end through the real startup flow (GstBillApp's own auto-refresh call on
/// launch is what carries the signal here, the same as session_ended_test).
void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Dastavez',
      packageName: 'com.dastavez.app',
      version: '1.0.0',
      buildNumber: '2002',
      buildSignature: '',
    );
  });
  var storeOpened = 0;
  setUp(() {
    // DAS-189: as on an Android phone, with the Play Store page "opened".
    debugCanOpenPlayStore = true;
    storeOpened = 0;
    debugOpenPlayStore = () async {
      storeOpened++;
      return true;
    };
  });
  tearDown(() {
    ApiClient.instance.onVersionGate = null;
    debugCanOpenPlayStore = null;
    debugOpenPlayStore = null;
  });

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
    expect(find.text('A new version of Dastavez is ready.'), findsOneWidget);
    expect(find.text('Your version: 1.0.0 (2002)'), findsOneWidget);
    // Not blocked: the home screen is still there underneath the banner.
    expect(find.byType(HomeScreen), findsOneWidget);

    // DAS-189: Update opens the Play Store page.
    await tester.tap(find.byKey(const ValueKey('update-nudge')));
    await tester.pump();
    expect(storeOpened, 1);

    await tester.tap(find.text('Later'));
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
    expect(find.text('This version of Dastavez has stopped working. Please update to keep using it.'), findsOneWidget);
    expect(find.text('Your version: 1.0.0 (2002)'), findsOneWidget);
    expect(find.textContaining("isn't found, email"), findsOneWidget, reason: 'the listing is closed testing');
    expect(find.text('Log out'), findsOneWidget);
    expect(find.byType(MaterialBanner), findsNothing, reason: 'no nudge left on top of the block');

    await tester.tap(find.byKey(const ValueKey('update-required')));
    await tester.pump();
    expect(storeOpened, 1);
  });

  testWidgets('with no Play Store (not Android), the banner has no Update button', (tester) async {
    debugCanOpenPlayStore = false;
    SharedPreferences.setMockInitialValues({});
    final payload = base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '');
    FlutterSecureStorage.setMockInitialValues({'token': 'h.$payload.s'});
    final client = MockClient((req) async => http.Response('{}', 200,
        headers: {'content-type': 'application/json', 'x-min-app-build': '9999'}));
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }, () => client);
    // The previous test left the gate at hard, so this soft level is a change and shows.
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.byKey(const ValueKey('update-nudge')), findsNothing);
    expect(find.text('Later'), findsOneWidget);
  });
}
