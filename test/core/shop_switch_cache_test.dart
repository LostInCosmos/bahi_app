import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/data/auth_api.dart';

// DAS-90: a different shop signing in leaves none of the previous shop's bill
// photos on disk; the same shop signing back in keeps all of its own. Real
// files, the real login path. Each cached file's name starts with its shop
// (`8/abc.jpg` is stored as `8_abc.jpg`), so nothing remembers the last shop
// — files already on disk before the first sign-in of a run are exactly what
// an app restart leaves behind.

String _tokenFor(int shop) => 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': shop}))).replaceAll('=', '')}.s';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory cache;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('shop_switch_cache_test');
    cache = Directory('${root.path}/bill_images');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync(recursive: true);
  });

  void seed(Iterable<String> names) {
    for (final n in names) {
      File('${cache.path}/$n').writeAsBytesSync([1, 2, 3]);
    }
  }

  Set<String> left() => {for (final f in cache.listSync().whereType<File>()) f.uri.pathSegments.last};

  MockClient serverFor(int shop) => MockClient((req) async {
        final body = switch (req.url.path) {
          '/auth/login' => {'access_token': _tokenFor(shop)},
          '/account' => {'tenant_name': 'Shop $shop', 'email': 'shop$shop@example.com'},
          _ => <String, dynamic>{},
        };
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      });

  Future<void> logIn(int shop) => http.runWithClient(
      () => ApiClient.instance.login(email: 'shop$shop@example.com', password: 'secret123'), () => serverFor(shop));

  /// The prune runs in the background, so wait until [gone] has gone — the
  /// sign that it has been through the folder.
  Future<void> prunedPast(String gone) async {
    for (var i = 0; i < 200 && left().contains(gone); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(left().contains(gone), isFalse, reason: 'the prune never ran');
  }

  test("a different shop signing in leaves none of the previous shop's photos", () async {
    seed(['9_a.jpg', '9_b.jpg_v_2', '81_c.jpg', '8_mine.jpg', '8_rotated.jpg_v_3']);

    await logIn(8);
    await prunedPast('9_a.jpg');

    expect(left(), {'8_mine.jpg', '8_rotated.jpg_v_3'},
        reason: "shop 9's and shop 81's go — 81 is not 8 just because it starts with an 8");
  });

  test('the same shop signing out and back in keeps every photo', () async {
    seed(['8_a.jpg', '8_b.jpg_v_2', '8_c.jpg']);
    await logIn(8);
    await http.runWithClient(() => ApiClient.instance.logout(), () => serverFor(8));

    seed(['9_marker.jpg']); // only so the second prune can be seen to finish
    await logIn(8);
    await prunedPast('9_marker.jpg');

    expect(left(), {'8_a.jpg', '8_b.jpg_v_2', '8_c.jpg'});
  });
}
