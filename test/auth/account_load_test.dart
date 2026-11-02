import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/presentation/account_screen.dart';

/// Quality pass: the account screen shows no form until the account has
/// loaded. It once showed empty fields over a failed load, and Save would
/// have sent them — the server clears a field sent as "".

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
  });
  tearDown(() => ApiClient.instance.token = null);

  testWidgets('a failed load shows the reason and Try again, no fields and no Save; Try again loads the form', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1600 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var fail = true;
    var patches = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: AccountScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Could not load account: Server error (503)'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Save details'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsNothing);
      expect(find.widgetWithText(TextField, 'Sharma Medical Store'), findsOneWidget);
      expect(find.text('Save details'), findsOneWidget);
    }, () => MockClient((req) async {
          if (req.url.path == '/account' && req.method == 'GET') {
            if (fail) return http.Response('<html>503 Service Unavailable</html>', 503);
            return _json({
              'tenant_name': 'Sharma Medical Store',
              'email': 's@example.com',
              'business_type': 'medical',
              'gstin': '09ABCDE1234F1Z5',
            });
          }
          if (req.url.path == '/account' && req.method == 'PATCH') patches++;
          return http.Response('no', 404);
        }));
    expect(patches, 0);
  });
}
