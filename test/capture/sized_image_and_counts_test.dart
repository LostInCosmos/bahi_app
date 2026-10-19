import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/data/capture_api.dart';
import 'package:gst_bill_app/features/invoice/data/invoice_api.dart';
import 'package:gst_bill_app/features/invoice/models/job_status.dart';

/// DAS-105, the small contracts: a thumbnail asks for a sized copy and caches
/// it under its own key; a refresh whose boxes are right skips the tally;
/// the status brief carries the review state and flag count.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // platform channels (storage, path_provider)
  late Directory root;
  setUpAll(() {
    root = Directory.systemTemp.createTempSync('sized_image_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() => ApiClient.instance.token = _token);
  tearDown(() => ApiClient.instance.token = null);

  test('fetchImage with a width asks ?w= and caches the sized copy apart from the full one', () async {
    final asked = <String>[];
    final client = MockClient((req) async {
      asked.add('${req.url.path}?${req.url.query}');
      final w = req.url.queryParameters['w'];
      return http.Response.bytes(Uint8List.fromList(w == null ? [1, 1, 1, 1] : [2]), 200,
          headers: {if (w != null) 'x-image-width': w});
    });
    await http.runWithClient(() async {
      final small = await ApiClient.instance.fetchImage('8/a.jpg', width: 640);
      final full = await ApiClient.instance.fetchImage('8/a.jpg');
      final again = await ApiClient.instance.fetchImage('8/a.jpg', width: 640);
      expect(small, [2]);
      expect(full, [1, 1, 1, 1]);
      expect(again, [2], reason: 'served from the cache under its own key');
      expect(asked, ['/invoices/image/8/a.jpg?w=640', '/invoices/image/8/a.jpg?']);
      // A rotation bumps the rev: a different key again, `w` first.
      await ApiClient.instance.fetchImage('8/a.jpg', width: 640, imageRev: 2);
      expect(asked.last, '/invoices/image/8/a.jpg?w=640&v=2');
    }, () => client);
  });

  test('imageCacheKey: no query for the plain case, so old cache entries are still found', () {
    expect(InvoiceApi.imageCacheKey('8/a.jpg'), '8/a.jpg');
    expect(InvoiceApi.imageCacheKey('8/a.jpg', imageRev: 3), '8/a.jpg?v=3');
    expect(InvoiceApi.imageCacheKey('8/a.jpg', width: 320), '8/a.jpg?w=320');
  });

  test('listUploads sends counts=false only when asked', () async {
    final queries = <Map<String, String>>[];
    final client = MockClient((req) async {
      queries.add(req.url.queryParameters);
      return http.Response(jsonEncode({'jobs': [], 'next_before_id': null, 'counts': null}), 200,
          headers: {'content-type': 'application/json'});
    });
    await http.runWithClient(() async {
      await ApiClient.instance.listUploads(folder: 'root');
      await ApiClient.instance.listUploads(folder: 'root', counts: false);
    }, () => client);
    expect(queries[0].containsKey('counts'), isFalse);
    expect(queries[1]['counts'], 'false');
  });

  test('a status brief carries review_state and flag_count when sent, null when not', () {
    final done = JobStatusBrief.fromJson({
      'job_id': 1, 'status': 'done', 'saved': false, 'review_state': 'pending', 'flag_count': 2,
    });
    expect(done.reviewState, 'pending');
    expect(done.flagCount, 2);
    final old = JobStatusBrief.fromJson({'job_id': 1, 'status': 'done'});
    expect(old.flagCount, isNull);
    expect(old.reviewState, isNull);
  });
}
