// ignore_for_file: avoid_print
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

import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/main.dart';

// DAS-86: measure what decoded bill images do across a logout. The disk cache
// (BillImageCache) is kept on purpose; this is the RAM side — Flutter's own
// ImageCache, which holds decoded bitmaps. Real images, decoded through the
// engine, and the app's real sign-out path.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

final _server = MockClient((req) async =>
    http.Response('{}', 200, headers: {'content-type': 'application/json'}));

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
  testWidgets('measure: decoded bill images across a logout', (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Dastavez', packageName: 'com.dastavez.bahi', version: '1.0.0', buildNumber: '2002', buildSignature: '');
    FlutterSecureStorage.setMockInitialValues({'token': _token});
    final cache = PaintingBinding.instance.imageCache..clear();

    late int heldBefore, bytesBefore, heldAfter, bytesAfter;
    await http.runWithClient(() async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(const GstBillApp());
      await _settle(tester);
      expect(find.byType(HomeScreen), findsOneWidget);

      // Six bills viewed at thumbnail size, as the capture grid decodes them.
      final context = tester.element(find.byType(HomeScreen));
      await tester.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          await precacheImage(MemoryImage(await _png(300 + i, 400)), context);
        }
      });
      heldBefore = cache.currentSize;
      bytesBefore = cache.currentSizeBytes;

      await tester.tap(find.byTooltip('Log out'));
      await _settle(tester);
      expect(find.byType(LoginScreen), findsOneWidget);
      heldAfter = cache.currentSize;
      bytesAfter = cache.currentSizeBytes;
    }, () => _server);

    print('MEASURED ImageCache: before logout $heldBefore images / ${(bytesBefore / 1024 / 1024).toStringAsFixed(2)} MiB, '
        'after $heldAfter images / ${(bytesAfter / 1024 / 1024).toStringAsFixed(2)} MiB; '
        'limits ${cache.maximumSize} images / ${cache.maximumSizeBytes ~/ (1024 * 1024)} MiB');

    expect(heldBefore, 6, reason: 'the decodes really landed in the cache');
    // The app sets no limit of its own, so Flutter's defaults bound it.
    expect(cache.maximumSizeBytes, 100 << 20);
    expect(cache.maximumSize, 1000);
  });
}
