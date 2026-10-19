// Renders the shared-name states for sign-off — not part of `flutter test`
// (it lives under tool/, so it only runs when named):
//
//   SCREENSHOT_DIR=/some/folder flutter test tool/screenshots/pack_qualifier_test.dart
//
// Real text: Roboto and the Material icon font are loaded from the Flutter
// SDK's cache, so the PNGs look like the phone rather than the test
// harness's box glyphs. The data is a made-up shop; nothing is fetched.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/app/theme/app_theme.dart';
import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/presentation/inventory_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';

final _outDir = Platform.environment['SCREENSHOT_DIR'] ?? Directory.systemTemp.path;

Future<void> _loadFonts() async {
  // The test runs on a dart binary somewhere under <flutter>/bin/cache; the
  // fonts are at <flutter>/bin/cache/artifacts/material_fonts.
  var dir = File(Platform.resolvedExecutable).parent;
  while (!Directory('${dir.path}/artifacts/material_fonts').existsSync()) {
    if (dir.parent.path == dir.path) throw StateError('material_fonts not found above ${Platform.resolvedExecutable}');
    dir = dir.parent;
  }
  final fonts = Directory('${dir.path}/artifacts/material_fonts');
  Future<ByteData> bytes(String f) async => ByteData.sublistView(await File('${fonts.path}/$f').readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(bytes('Roboto-Regular.ttf'))
    ..addFont(bytes('Roboto-Medium.ttf'))
    ..addFont(bytes('Roboto-Bold.ttf'));
  final icons = FontLoader('MaterialIcons')..addFont(bytes('MaterialIcons-Regular.otf'));
  await Future.wait([roboto.load(), icons.load()]);
}

Map<String, Object?> _row(int id, String name, {String? pack, double? mrp, double stock = 12}) => {
      'id': id,
      'name': name,
      'hsn_code': '3004',
      'pack': pack,
      'quantity_on_hand': stock,
      'net_rate': mrp == null ? null : (mrp * 0.8),
      'mrp': mrp,
      'expiry_date': mrp == null ? null : '2027-03-31',
    };

/// An ordinary shop: every name once. Packs exist but are not shown.
final ordinary = [
  _row(1, 'Crocin Advance', pack: '15 Tab', mrp: 30),
  _row(2, 'Dolo 650', pack: '15 Tab', mrp: 31),
  _row(3, 'Himalaya Liv.52', pack: '100 Tab', mrp: 165),
  _row(4, 'Prominent Charcoal', pack: '60GM', mrp: 140),
  _row(5, 'Volini Gel', pack: '30GM', mrp: 110, stock: 0),
];

/// The same brand in two packs (ADR-020): both rows name their pack.
final sharedPacks = [
  ...ordinary.sublist(0, 4),
  _row(6, 'Prominent Charcoal', pack: '100GM', mrp: 185),
  ordinary[4],
];

/// One of the two has no pack on record: it shows its MRP instead.
final nullPack = [
  ...ordinary.sublist(0, 4),
  _row(6, 'Prominent Charcoal', mrp: 185),
  ordinary[4],
];

MockClient _server(List<Map<String, Object?>> rows) => MockClient((req) async {
      if (req.url.path == '/inventory/products') {
        return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'});
      }
      return http.Response('not found', 404);
    });

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shoot(WidgetTester tester, GlobalKey key, String file) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('$_outDir/$file');
    await out.writeAsBytes(png!.buffer.asUint8List());
    debugPrint('wrote ${out.path}');
  });
}

Widget _phone(GlobalKey key, Widget home) => RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: Brightness.light),
        home: home,
      ),
    );

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    ApiClient.instance.token = 'screenshot-${DateTime.now().microsecondsSinceEpoch}';
    // A mid-range phone: 390×844 logical, 2× density.
  });
  tearDown(() => ApiClient.instance.token = null);

  Future<void> inventory(WidgetTester tester, List<Map<String, Object?>> rows, String file) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    tester.view.devicePixelRatio = 2;
    final shot = GlobalKey();
    final screen = GlobalKey<InventoryScreenState>();
    await http.runWithClient(() async {
      await tester.pumpWidget(_phone(
        shot,
        Scaffold(appBar: AppBar(title: const Text('Inventory')), body: InventoryScreen(key: screen)),
      ));
      await screen.currentState!.refresh();
      await _settle(tester);
      await _shoot(tester, shot, file);
    }, () => _server(rows));
  }

  testWidgets('inventory: ordinary list', (t) => inventory(t, ordinary, 'inventory_ordinary.png'));
  testWidgets('inventory: same name, two packs', (t) => inventory(t, sharedPacks, 'inventory_shared_packs.png'));
  testWidgets('inventory: same name, one pack missing', (t) => inventory(t, nullPack, 'inventory_null_pack.png'));

  testWidgets('sell tab: same name, two packs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    tester.view.devicePixelRatio = 2;
    final shot = GlobalKey();
    final screen = GlobalKey<SalesScreenState>();
    await http.runWithClient(() async {
      await tester.pumpWidget(_phone(shot, SalesScreen(key: screen)));
      await screen.currentState!.refresh();
      await _settle(tester);
      await _shoot(tester, shot, 'sell_shared_packs.png');
    }, () => _server(sharedPacks));
  });
}
