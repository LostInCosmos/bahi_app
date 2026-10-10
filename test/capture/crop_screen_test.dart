import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/presentation/crop_screen.dart';

/// Confirming a crop before the photo had loaded returned no corners, which
/// every caller reads as "cancelled": the photo was silently dropped.

// A 1x1 PNG.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

FilledButton _confirm(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm this page'));

Future<void> _open(WidgetTester tester, Uint8List bytes) async {
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  await tester.pumpWidget(MaterialApp(home: CropScreen(imageBytes: bytes)));
}

/// The image decodes on the engine, outside the test's fake clock.
Future<void> _letItDecode(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  testWidgets('nothing can be confirmed until the photo has loaded', (tester) async {
    await _open(tester, _png);
    expect(_confirm(tester).onPressed, isNull, reason: 'no corners yet');

    await _letItDecode(tester);
    expect(_confirm(tester).onPressed, isNotNull);
  });

  testWidgets('a file that is not a photo says so, and stays unconfirmable', (tester) async {
    await _open(tester, Uint8List.fromList(utf8.encode('not an image')));
    await _letItDecode(tester);

    expect(find.textContaining("Couldn't open this photo"), findsOneWidget);
    expect(_confirm(tester).onPressed, isNull);
  });
}
