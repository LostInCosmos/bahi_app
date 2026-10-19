import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/data/auth_api.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/main.dart';

// DAS-90. DAS-86 measured that Flutter's ImageCache — the decoded bitmaps of
// the bills a shop looked at — survived a logout: 6 bills, 2.77 MiB, still
// held after signing out, bounded only by Flutter's 100 MiB default. Both
// ways a session ends now let go of them. Real images, decoded through the
// engine, and the app's real sign-out paths.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF336699));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late bool refuse;
  final server = MockClient((req) async => refuse
      ? http.Response(jsonEncode({'detail': 'token revoked'}), 401, headers: {'content-type': 'application/json'})
      : http.Response('{}', 200, headers: {'content-type': 'application/json'}));

  setUp(() {
    refuse = false;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Dastavez', packageName: 'com.dastavez.bahi', version: '1.0.0', buildNumber: '2002', buildSignature: '');
    FlutterSecureStorage.setMockInitialValues({'token': _token});
    imageCache.clear();
  });

  void ignoreOverflow() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  /// Signed in, with six bills decoded at thumbnail size as the grid does.
  Future<void> signedInWithBills(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpWidget(const GstBillApp());
    await _settle(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    final context = tester.element(find.byType(HomeScreen));
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await precacheImage(MemoryImage(await _png(300 + i, 400)), context);
      }
    });
    expect(imageCache.currentSize, 6, reason: 'the decodes really landed in the cache');
  }

  testWidgets('logging out lets go of the decoded bill images', (tester) async {
    ignoreOverflow();
    await http.runWithClient(() async {
      await signedInWithBills(tester);
      await tester.tap(find.byTooltip('Log out'));
      await _settle(tester);
    }, () => server);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(imageCache.currentSize, 0);
    expect(imageCache.currentSizeBytes, 0);
  });

  testWidgets('a session the server ends lets go of them too', (tester) async {
    ignoreOverflow();
    await http.runWithClient(() async {
      await signedInWithBills(tester);
      refuse = true; // signed out on another device
      try {
        await ApiClient.instance.getAccount();
      } on ApiException catch (_) {
        // the 401 is the point: it ends the session
      }
      await _settle(tester);
    }, () => server);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(imageCache.currentSize, 0);
  });
}
