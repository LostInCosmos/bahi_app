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
import 'package:gst_bill_app/core/utils/app_foreground.dart';
import 'package:gst_bill_app/core/utils/poll.dart';
import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

// DAS-131: capture when Android (or iOS) takes the app away. Measured in
// DAS-126 on the Android 15 emulator: 5 s after the app leaves the screen the
// OS destroys its sockets and refuses new ones until it is back. These drive
// the real screen against a fake server, with the lifecycle fed through
// AppForeground.applyState as the app's listener would.

const _key = 'bahi_batch_8';
final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

/// The parts of the server every test needs, plus a held status request.
Future<http.Response?> _common(http.Request req) async {
  final path = req.url.path;
  if (req.method == 'GET' && path == '/folders') return _json([]);
  if (req.method == 'GET' && path == '/invoices/extract') return _json({'jobs': [], 'next_before_id': null});
  return null;
}

/// Lets real file I/O (the pending-photo store) finish, then draws.
Future<void> _io(WidgetTester tester) async {
  // Interleaved: each file step needs real time, and each continuation a frame.
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpScreen(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
}

void main() {
  late Directory dir;

  setUpAll(() {
    // One real folder for the file: PendingPhotoStore remembers its folder
    // for the life of the process.
    dir = Directory.systemTemp.createTempSync('capture_background_test');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    AppForeground.reset();
    ApiClient.instance.token = _token;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  });
  tearDown(() {
    AppForeground.reset();
    ApiClient.instance.token = null;
    debugRetrieveLostData = () => ImagePicker().retrieveLostData();
  });

  testWidgets('the status loop stops asking while the app is away and asks at once on return', (tester) async {
    SharedPreferences.setMockInitialValues({
      _key: jsonEncode([
        {'label': 'Photo 1', 'sourceImages': ['8/5.jpg'], 'pages': [], 'status': 'processing', 'jobId': 5, 'lastJobId': 5},
      ]),
    });
    var asks = 0;
    final client = MockClient((req) async {
      final common = await _common(req);
      if (common != null) return common;
      if (req.method == 'POST' && req.url.path == '/invoices/extract/status') {
        asks++;
        await Future<void>.delayed(const Duration(seconds: 25)); // held, as the real server does
        return _json({
          'jobs': [
            {'job_id': 5, 'status': 'processing', 'attempt': 1, 'max_attempts': 3},
          ],
          'changed': false,
        });
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await _pumpScreen(tester);
      await _io(tester);
      expect(asks, 1, reason: 'the restored bill is being read, so it is asked about');

      AppForeground.applyState(AppLifecycleState.hidden);
      AppForeground.applyState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 26)); // the held request answers
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 10)); // two minutes away
      }
      expect(asks, 1, reason: 'nothing is asked while the app is away');

      AppForeground.applyState(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(asks, 2, reason: 'asked the moment the app is back, not after a pause');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }, () => client);
  });

  testWidgets('an upload cut while the app is away is not failed, and goes up again on return', (tester) async {
    final photos = Directory('${dir.path}/pending_photos')..createSync(recursive: true);
    File('${photos.path}/8_p1.jpg').writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    SharedPreferences.setMockInitialValues({
      _key: jsonEncode([
        {
          'label': 'Photo 1',
          'sourceImages': [],
          'pages': [
            {
              'photoId': '8_p1',
              'filename': 'bill.jpg',
              'corners': [
                [0, 0],
                [1, 0],
                [1, 1],
                [0, 1]
              ],
              'rotation': 0,
            }
          ],
          'status': 'preparing',
        },
      ]),
    });
    var uploads = 0;
    var submitted = 0;
    final client = MockClient((req) async {
      final common = await _common(req);
      if (common != null) return common;
      final path = req.url.path;
      if (req.method == 'POST' && path == '/invoices/preprocess') {
        uploads++;
        if (uploads == 1) {
          // The shopkeeper switches apps mid-upload; Android cuts the socket.
          AppForeground.applyState(AppLifecycleState.hidden);
          throw http.ClientException('Connection reset by peer');
        }
        return _json({'source_image': '8/new.jpg'});
      }
      if (req.method == 'POST' && path == '/invoices/extract') {
        submitted++;
        return _json({'job_id': 9});
      }
      if (req.method == 'POST' && path == '/invoices/extract/status') {
        await Future<void>.delayed(const Duration(seconds: 25));
        return _json({
          'jobs': [
            {'job_id': 9, 'status': 'processing', 'attempt': 1, 'max_attempts': 3},
          ],
          'changed': false,
        });
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await _pumpScreen(tester);
      await _io(tester);
      expect(uploads, 1);
      expect(find.textContaining('Upload failed'), findsNothing, reason: 'the platform cut it, not the shopkeeper');
      final stored = jsonDecode((await SharedPreferences.getInstance()).getString(_key)!) as List;
      expect(stored.single['status'], 'preparing', reason: 'still waiting to go up, photo still on disk');
      expect(File('${photos.path}/8_p1.jpg').existsSync(), isTrue);

      AppForeground.applyState(AppLifecycleState.resumed);
      await _io(tester);
      expect(uploads, 2, reason: 'sent again the moment the app is back');
      expect(submitted, 1, reason: 'and handed to the server to be read');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }, () => client);
  });

  testWidgets('an upload that fails while the app is on screen still says so', (tester) async {
    final photos = Directory('${dir.path}/pending_photos')..createSync(recursive: true);
    File('${photos.path}/8_p2.jpg').writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    SharedPreferences.setMockInitialValues({
      _key: jsonEncode([
        {
          'label': 'Photo 1',
          'sourceImages': [],
          'pages': [
            {
              'photoId': '8_p2',
              'filename': 'bill.jpg',
              'corners': [
                [0, 0],
                [1, 0],
                [1, 1],
                [0, 1]
              ],
              'rotation': 0,
            }
          ],
          'status': 'preparing',
        },
      ]),
    });
    final client = MockClient((req) async {
      final common = await _common(req);
      if (common != null) return common;
      if (req.method == 'POST' && req.url.path == '/invoices/preprocess') {
        throw http.ClientException('Connection reset by peer');
      }
      return http.Response('not found', 404);
    });

    await http.runWithClient(() async {
      await _pumpScreen(tester);
      await _io(tester);
      final stored = jsonDecode((await SharedPreferences.getInstance()).getString(_key)!) as List;
      expect(stored.single['status'], 'failed', reason: 'a real failure on screen is shown, with Retry');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5)); // the idle status loop's last tick
    }, () => client);
  });

  testWidgets('a photo Android kept when it ended the app is recovered into the crop on relaunch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugRetrieveLostData = () async => LostDataResponse(
          files: [XFile.fromData(Uint8List.fromList(List.filled(32, 1)), name: 'lost.jpg')],
          type: RetrieveType.image,
        );
    final client = MockClient((req) async => await _common(req) ?? http.Response('not found', 404));

    await http.runWithClient(() async {
      await _pumpScreen(tester);
      await _io(tester);
      expect(find.text('Recovered the photo you took before the app closed.'), findsOneWidget);
      expect(find.text('Adjust corners'), findsOneWidget, reason: 'straight into the normal crop, as if just taken');
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('nothing lost: no message and no crop', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugRetrieveLostData = () async => LostDataResponse.empty();
    final client = MockClient((req) async => await _common(req) ?? http.Response('not found', 404));

    await http.runWithClient(() async {
      await _pumpScreen(tester);
      await _io(tester);
      expect(find.textContaining('Recovered'), findsNothing);
      expect(find.text('Adjust corners'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  test('a voice wait cut by the app leaving is not counted as a failure', () async {
    var calls = 0;
    final result = pollUntilTerminal<String>(
      fetch: () async {
        calls++;
        if (calls == 1) {
          AppForeground.applyState(AppLifecycleState.paused);
          throw http.ClientException('Software caused connection abort');
        }
        return 'done';
      },
      isTerminal: (s) => s == 'done',
      transientFailures: 0, // would rethrow the first ordinary failure
      transientBackoff: Duration.zero,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, 1, reason: 'waits for the app to come back before asking again');
    AppForeground.applyState(AppLifecycleState.resumed);
    expect(await result, 'done');
    expect(calls, 2);
  });
}
