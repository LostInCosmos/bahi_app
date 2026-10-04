import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/widgets/bill_thumbnail.dart';

// A real bill is ~1715x1927px. `BoxFit` only scales at PAINT time, so without
// `cacheWidth` every visible card decodes at native resolution — ~12.6 MB of
// bitmap each, to be drawn at about 117dp wide. Flutter's ImageCache caps
// around 100 MB, so a 3-across grid does not grow unbounded; it thrashes,
// evicting and re-decoding while you scroll.
//
// These measure the decoded bytes Flutter actually holds, rather than
// asserting a parameter was passed, so they would still fail if cacheWidth
// stopped having the intended effect.

const _billWidth = 1715;
const _billHeight = 1927;

/// Bitmap bytes for the whole image at native resolution, 4 bytes per pixel.
const _fullResBytes = _billWidth * _billHeight * 4;

Future<Uint8List> _billSizedPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Some structure, so the encoder cannot collapse it to almost nothing.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, _billWidth.toDouble(), _billHeight.toDouble()),
    Paint()..color = const Color(0xFFEFEFEF),
  );
  for (var y = 0; y < _billHeight; y += 40) {
    canvas.drawRect(
      Rect.fromLTWH(0, y.toDouble(), _billWidth.toDouble(), 18),
      Paint()..color = const Color(0xFF334455),
    );
  }
  final image = await recorder.endRecording().toImage(_billWidth, _billHeight);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

int get _cacheBytes => PaintingBinding.instance.imageCache.currentSizeBytes;

/// Decoding is real async work off the test clock, so it needs runAsync —
/// pumpAndSettle alone leaves the cache empty and every `lessThan` assertion
/// below would pass against zero without proving anything.
Future<void> _settleImages(WidgetTester tester, Widget app) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(app);
    for (var i = 0; i < 20 && _cacheBytes == 0; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
}

Widget _card(Uint8List bytes, {required double side}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: side,
            height: side,
            child: BillThumbnail(sourceImage: '7/a.jpg', loader: (_) async => bytes),
          ),
        ),
      ),
    );

void main() {
  late Uint8List bill;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    bill = await _billSizedPng();
  });

  setUp(() => PaintingBinding.instance.imageCache.clear());

  testWidgets('a card decodes at its own size, not the size the bill was photographed at',
      (tester) async {
    await _settleImages(tester, _card(bill, side: 117));

    final decoded = _cacheBytes;
    expect(decoded, greaterThan(0), reason: 'the image really was decoded');
    expect(
      decoded,
      lessThan(_fullResBytes ~/ 4),
      reason: 'decoded $decoded bytes; full resolution would be $_fullResBytes',
    );
  });

  testWidgets('twelve visible cards stay far below the ImageCache ceiling', (tester) async {
    // The case that thrashes: at full resolution twelve of these want ~151 MB
    // against a ~100 MB cache, so Flutter evicts and re-decodes as you scroll.
    await _settleImages(
      tester,
      MaterialApp(
        home: Scaffold(
          body: GridView.count(
            crossAxisCount: 3,
            children: [
              for (var i = 0; i < 12; i++)
                BillThumbnail(sourceImage: '7/bill$i.jpg', loader: (_) async => bill),
            ],
          ),
        ),
      ),
    );

    final decoded = _cacheBytes;
    expect(decoded, greaterThan(0), reason: 'guards against a vacuous pass');
    expect(decoded, lessThan(12 * _fullResBytes ~/ 4));
    expect(decoded, lessThan(100 * 1024 * 1024),
        reason: 'must fit the cache without evicting, or scrolling re-decodes');
  });

  testWidgets('a bigger card decodes more than a smaller one', (tester) async {
    await _settleImages(tester, _card(bill, side: 60));
    final small = _cacheBytes;

    PaintingBinding.instance.imageCache.clear();
    await _settleImages(tester, _card(bill, side: 300));
    final large = _cacheBytes;

    expect(small, greaterThan(0));
    expect(large, greaterThan(small),
        reason: 'decode size should track the card, not be a fixed constant');
    expect(large, lessThan(_fullResBytes), reason: 'still under native resolution');
  });

  testWidgets('a failed load shows the broken state rather than spinning', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BillThumbnail(
          sourceImage: '7/gone.jpg',
          loader: (_) async => throw Exception('404'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a bill with no server path yet just waits', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: BillThumbnail(sourceImage: null)),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
