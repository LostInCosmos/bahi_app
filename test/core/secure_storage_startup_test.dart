import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';

// DAS-135: a Keychain or Keystore that cannot be read at launch (some devices
// refuse right after boot; a restored backup cannot unwrap its key) used to
// throw out of loadFromDisk and leave the app on its spinner. It now means
// "signed out": the login screen is the way back.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    ApiClient.instance.token = null;
  });

  test('an unreadable secure store at launch signs the device out instead of throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'Exception encountered', message: 'Failed to unwrap key');
    });
    ApiClient.instance.token = 'stale';

    await ApiClient.instance.loadFromDisk();

    expect(ApiClient.instance.token, isNull);
    expect(ApiClient.instance.isLoggedIn, isFalse);
  });

  test('a token an older build left in shared_preferences still signs in when the store cannot be written', () async {
    SharedPreferences.setMockInitialValues({'token': 'h.e30.s'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') return null;
      throw PlatformException(code: 'Exception encountered', message: 'Keystore busy');
    });

    await ApiClient.instance.loadFromDisk();

    expect(ApiClient.instance.token, 'h.e30.s');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'h.e30.s', reason: 'kept until a secure write succeeds');
  });
}
