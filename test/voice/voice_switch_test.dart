import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/data/auth_api.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';
import 'package:gst_bill_app/features/voice/widgets/recording.dart';

/// DAS-112: the admin can switch voice off for a shop. The server says so on
/// every authenticated response (`X-Voice-Enabled: 1|0`) and in the login and
/// account answers; the phone hides both mics, leaves a draft already open
/// alone, and shows the server's refusal in words if a voice request is
/// turned down before the header has arrived.

final _token = 'h.${base64Url.encode(utf8.encode(jsonEncode({'tenant_id': 8}))).replaceAll('=', '')}.s';

http.Response _answer(Object body, {String? voice, int status = 200}) => http.Response(jsonEncode(body), status,
    headers: {'content-type': 'application/json', if (voice != null) 'x-voice-enabled': voice});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = ApiClient.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    api.token = _token;
    api.voiceEnabledNotifier.value = true;
  });
  tearDown(() {
    api.token = null;
    api.voiceEnabledNotifier.value = true;
  });

  Future<void> call(String? voice, {bool auth = true}) => http.runWithClient(
        () => api.postJson('/anything', {}, auth: auth),
        () => MockClient((_) async => _answer({}, voice: voice)),
      );

  test('the header turns voice off and on, and a missing header changes nothing', () async {
    expect(api.voiceEnabledNotifier.value, isTrue, reason: 'on until told otherwise');
    await call('0');
    expect(api.voiceEnabledNotifier.value, isFalse);
    await call(null);
    expect(api.voiceEnabledNotifier.value, isFalse, reason: 'no header is "no change", never "off" or "on"');
    await call('1');
    expect(api.voiceEnabledNotifier.value, isTrue);
    await call(null);
    expect(api.voiceEnabledNotifier.value, isTrue);
  });

  test('a call that carried no token does not move the switch', () async {
    await call('0', auth: false);
    expect(api.voiceEnabledNotifier.value, isTrue);
  });

  test('the switch is remembered per shop on the device', () async {
    await call('0');
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('voice_enabled_8'), isFalse);
    expect(prefs.getBool('voice_enabled_9'), isNull, reason: 'another shop is untouched');
  });

  test('login carries the switch; an older server (no field) leaves voice on', () async {
    Future<void> login(Map<String, dynamic> account) => http.runWithClient(
          () => api.login(email: 'k@x.in', password: 'p'),
          () => MockClient((_) async => _answer({'access_token': _token, 'account': account})),
        );
    api.token = null;
    await login({'tenant_name': 'K', 'email': 'k@x.in', 'business_type': 'medical', 'voice_enabled': false});
    expect(api.voiceEnabledNotifier.value, isFalse);

    api.token = null;
    api.voiceEnabledNotifier.value = true;
    await login({'tenant_name': 'K', 'email': 'k@x.in', 'business_type': 'medical'});
    expect(api.voiceEnabledNotifier.value, isTrue);
  });

  test('a refused voice request shows the server\'s sentence as it is, and switches voice off here', () {
    final shown = voiceOffMessage(ApiException(403, 'Voice is turned off for this shop. Please contact us.'));
    expect(shown, 'Voice is turned off for this shop. Please contact us.');
    expect(api.voiceEnabledNotifier.value, isFalse);
  });

  testWidgets('the home screen has the voice command button, and loses it when voice goes off', (tester) async {
    api.token = null; // every tab builds without a request
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    expect(find.byTooltip('Voice command'), findsOneWidget);
    api.voiceEnabledNotifier.value = false;
    await tester.pump();
    expect(find.byTooltip('Voice command'), findsNothing);
    expect(find.byTooltip('Account'), findsOneWidget, reason: 'the rest of the bar is untouched');
    api.voiceEnabledNotifier.value = true;
    await tester.pump();
    expect(find.byTooltip('Voice command'), findsOneWidget);
  });

  testWidgets('the Sell tab has the voice sale button, and loses it when voice goes off', (tester) async {
    api.token = null;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SalesScreen())));
    await tester.pump();
    expect(find.byTooltip('Voice sale'), findsOneWidget);
    api.voiceEnabledNotifier.value = false;
    await tester.pump();
    expect(find.byTooltip('Voice sale'), findsNothing);
  });
}
