import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/widgets/qr_code_view.dart';
import 'package:gst_bill_app/features/auth/presentation/account_screen.dart';

// The shop's public stock page (DAS-80) on the Account screen: the link the
// server sends as `public_stock_url`, to copy or share, and a QR code for
// customers. Null for a shop with no page: then the screen says how to ask.

final _token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
const _url = 'https://dastavez.co.in/sharma-medical';
const _poster = 'https://dastavez.co.in/sharma-medical/poster';
const _absent = Object();

/// [poster]: a server that sends `public_poster_url`; left out, the server is
/// older than the field and the response has no such key.
MockClient _server(String? url, {Object? poster = _absent}) => MockClient((req) async => http.Response(
    jsonEncode({
      'tenant_name': 'Sharma Medical Store',
      'email': 's@example.com',
      'business_type': 'medical',
      'public_stock_url': url,
      if (poster != _absent) 'public_poster_url': poster,
    }),
    200,
    headers: {'content-type': 'application/json'}));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ApiClient.instance.token = _token;
  });
  tearDown(() => ApiClient.instance.token = null);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 2400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AccountScreen()));
    await tester.pumpAndSettle();
  }

  Finder inRow(String key, String label) =>
      find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(label));

  testWidgets('a published page shows both links, each with Copy, Share and Open, and a QR of the page', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await http.runWithClient(() async {
      await open(tester);
      expect(find.text('Your stock page'), findsOneWidget);
      expect(find.text(_url), findsOneWidget);
      expect(find.text(_poster), findsOneWidget);
      expect(tester.widget<QrCodeView>(find.byType(QrCodeView)).data, _url, reason: 'the code opens the same link');
      for (final row in ['stock-url', 'poster-url']) {
        for (final action in ['Copy', 'Share', 'Open']) {
          expect(inRow(row, action), findsOneWidget, reason: '$row has $action');
        }
      }

      await tester.tap(inRow('stock-url', 'Copy'));
      await tester.pumpAndSettle();
      await tester.tap(inRow('poster-url', 'Copy'));
      await tester.pumpAndSettle();
      expect(copied, [_url, _poster]);
      expect(find.text('Link copied'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('stock-qr')));
      await tester.pumpAndSettle();
      expect(find.text('Scan to see which medicines are in stock'), findsOneWidget);
      expect(find.text('Sharma Medical Store'), findsWidgets);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Scan to see which medicines are in stock'), findsNothing);
    }, () => _server(_url, poster: _poster));
  });

  testWidgets('a server older than the poster field: the poster link is the page link plus /poster', (tester) async {
    await http.runWithClient(() async {
      await open(tester);
      expect(find.text(_poster), findsOneWidget);
    }, () => _server(_url));
  });

  testWidgets('a server that sends no poster shows only the page link', (tester) async {
    await http.runWithClient(() async {
      await open(tester);
      expect(find.text(_url), findsOneWidget);
      expect(find.byKey(const ValueKey('poster-url')), findsNothing);
    }, () => _server(_url, poster: null));
  });

  testWidgets('a shop with no live page sees no stock page block at all', (tester) async {
    await http.runWithClient(() async {
      await open(tester);
      expect(find.text('Your stock page'), findsNothing);
      expect(find.byType(QrCodeView), findsNothing);
      expect(find.text('Copy'), findsNothing);
      expect(find.textContaining('/poster'), findsNothing);
    }, () => _server(null, poster: null));
  });

  test('the code is a standard QR of the link, at a size phone cameras read', () {
    final code = QrCode.fromData(data: _url, errorCorrectLevel: QrErrorCorrectLevel.M);
    expect(code.typeNumber, lessThanOrEqualTo(4), reason: 'a short link stays a coarse, easy code');
    final image = QrImage(code);
    expect(image.moduleCount, 21 + 4 * (code.typeNumber - 1));
  });
}
