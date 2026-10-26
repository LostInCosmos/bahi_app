import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

// DAS-131 item 5: a multi-page bill is in the batch from its first page, as
// a draft, so Android ending the app mid-bill loses no page. On relaunch its
// card says "N pages · not sent"; tapping it offers Add another page, Send,
// Discard (the user's choice of screens, 2026-10-27). Also: a photo picked
// from the gallery and still waiting for its corners is no longer uploaded
// on its own at restart.

const _key = 'bahi_batch_8';
final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _page(String id) => {
      'photoId': id,
      'filename': '$id.jpg',
      'corners': [
        [0, 0],
        [1, 0],
        [1, 1],
        [0, 1]
      ],
      'rotation': 0,
    };

class _Server {
  var uploads = 0;
  var submitted = 0;

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') return _json({'jobs': [], 'next_before_id': null});
        if (req.method == 'POST' && path == '/invoices/preprocess') {
          uploads++;
          return _json({'source_image': '8/p$uploads.jpg'});
        }
        if (req.method == 'POST' && path == '/invoices/extract') {
          submitted++;
          return _json({'job_id': 40});
        }
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          await Future<void>.delayed(const Duration(seconds: 25));
          return _json({
            'jobs': [
              {'job_id': 40, 'status': 'processing', 'attempt': 1, 'max_attempts': 3},
            ],
            'changed': false,
          });
        }
        return http.Response('not found', 404);
      });
}

/// Enough frames for a dialog to open or close. Not pumpAndSettle: the
/// status loop's idle ticks keep scheduling timers, so it never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets real file I/O (the pending-photo store) finish, then draws.
Future<void> _io(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory dir;
  late Directory photos;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('capture_draft_test');
    photos = Directory('${dir.path}/pending_photos')..createSync(recursive: true);
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    ApiClient.instance.token = _token;
    debugRetrieveLostData = () async => LostDataResponse.empty();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    for (final f in photos.listSync()) {
      f.deleteSync();
    }
  });
  tearDown(() {
    ApiClient.instance.token = null;
    debugRetrieveLostData = () => ImagePicker().retrieveLostData();
  });

  void photo(String id) => File('${photos.path}/$id.jpg').writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));

  Future<void> start(WidgetTester tester, List<Map<String, dynamic>> batch) async {
    SharedPreferences.setMockInitialValues({_key: jsonEncode(batch)});
    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
    await _io(tester);
  }

  Map<String, dynamic> draft(List<String> ids) => {
        'label': 'Photo 1',
        'sourceImages': [],
        'pages': [for (final id in ids) _page(id)],
        'status': 'needsCrop',
        'draft': true,
      };

  testWidgets('a bill left mid-way comes back as "2 pages · not sent" and is not sent on its own', (tester) async {
    photo('8_a');
    photo('8_b');
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester, [draft(['8_a', '8_b'])]);

      expect(find.text('2 pages · not sent'), findsOneWidget);
      expect(server.uploads, 0, reason: 'a bill that may be missing a page waits for the shopkeeper');

      await tester.tap(find.text('2 pages · not sent'));
      await _frames(tester);
      expect(find.text('This bill has 2 pages'), findsOneWidget);
      expect(find.text('+ Add another page'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      await tester.tap(find.text('Send 2 pages'));
      await _io(tester);
      expect(server.uploads, 2, reason: 'both pages go up');
      expect(server.submitted, 1, reason: 'as one bill');
      expect(find.text('2 pages · not sent'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }, () => server.client);
  });

  testWidgets('Discard asks first, then deletes the photos from the phone', (tester) async {
    photo('8_c');
    photo('8_d');
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester, [draft(['8_c', '8_d'])]);

      await tester.tap(find.text('2 pages · not sent'));
      await _frames(tester);
      await tester.tap(find.text('Discard'));
      await _frames(tester);
      expect(find.text('Discard this bill?'), findsOneWidget);
      expect(find.text('Its 2 photos are deleted from this phone.'), findsOneWidget);

      // The confirmation's destructive button (the draft dialog behind it is gone).
      await tester.tap(find.text('Discard').last);
      await _io(tester);
      expect(find.text('2 pages · not sent'), findsNothing);
      expect(File('${photos.path}/8_c.jpg').existsSync(), isFalse);
      expect(File('${photos.path}/8_d.jpg').existsSync(), isFalse);
      expect(server.uploads, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => server.client);
  });

  testWidgets('the cross on an unsent bill asks too, and Cancel keeps it', (tester) async {
    photo('8_e');
    photo('8_f');
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester, [draft(['8_e', '8_f'])]);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await _frames(tester);
      expect(find.text('Discard this bill?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.text('2 pages · not sent'), findsOneWidget);
      expect(File('${photos.path}/8_e.jpg').existsSync(), isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => server.client);
  });

  testWidgets('a gallery photo still waiting for its corners is not uploaded at restart', (tester) async {
    photo('8_g');
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester, [
        {'label': 'Photo 1', 'sourceImages': [], 'pages': [_page('8_g')..['corners'] = []], 'status': 'needsCrop'},
      ]);
      expect(server.uploads, 0, reason: 'nobody has chosen its corners yet');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => server.client);
  });

  testWidgets('a photo Android kept while page 2 was being taken joins the unsent bill', (tester) async {
    photo('8_h');
    debugRetrieveLostData = () async => LostDataResponse(
          files: [XFile.fromData(Uint8List.fromList(List.filled(32, 1)), name: 'page2.jpg')],
          type: RetrieveType.image,
        );
    final server = _Server();
    await http.runWithClient(() async {
      await start(tester, [draft(['8_h'])]);
      expect(find.text('Recovered the page you took before the app closed.'), findsOneWidget);
      expect(find.text('Page 2 of this bill — drag the four handles onto its corners.'), findsOneWidget,
          reason: 'cropped as the next page of the unsent bill, not as a new bill');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => server.client);
  });
}
