import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/auth/presentation/account_screen.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_receipt_screen.dart';

/// DAS-121: the shop's drug licence number and phone — asked at signup,
/// edited in Account, printed on bills; the receipt nudges while either is
/// missing.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

final _token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';

Map<String, dynamic> _account({String? dlNo, String? phone}) => {
      'tenant_name': 'Sharma Medical Store',
      'email': 's@example.com',
      'business_type': 'medical',
      'gstin': '09ABCDE1234F1Z5',
      'dl_no': dlNo,
      'phone': phone,
    };

Map<String, dynamic> _sale() => {
      'id': 5,
      'sale_no': '2026-27/0042',
      'sale_date': '2026-10-25',
      'subtotal': 100,
      'total_cgst': 5.36,
      'total_sgst': 5.36,
      'grand_total': 112,
      'line_items': [
        {'product_name': 'Dolo', 'qty': 1, 'rate': 112, 'gst_pct': 12, 'cgst_amount': 6, 'sgst_amount': 6, 'line_amount': 112},
      ],
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => ApiClient.instance.token = null);

  void tallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 1600 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> fillSignup(WidgetTester tester, {required String dlNo, required String phone}) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Shop / tenant name'), 'Sharma Medical Store');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 's@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret123');
    await tester.enterText(find.widgetWithText(TextField, 'Drug licence no. (optional)'), dlNo);
    await tester.enterText(find.widgetWithText(TextField, 'Shop phone (optional)'), phone);
    await tester.ensureVisible(find.byKey(const ValueKey('accept-terms')));
    await tester.tap(find.byKey(const ValueKey('accept-terms')));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create account'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
  }

  testWidgets('signup sends both fields, and shows the server\'s refusal under the phone', (tester) async {
    tallPhone(tester);
    Map<String, dynamic>? body;
    await http.runWithClient(() async {
      await fillSignup(tester, dlNo: '  20B/UP7820B001234 ', phone: '98390 123');
    }, () => MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'detail': 'Enter a 10-digit phone number.'}, 422);
        }));
    expect(body!['dl_no'], '20B/UP7820B001234');
    expect(body!['phone'], '98390 123', reason: 'the server cleans and checks it');
    expect(body!['legal_version'], '1.2');
    final phone = tester.widget<TextField>(find.widgetWithText(TextField, 'Shop phone (optional)'));
    expect(phone.decoration!.errorText, 'Enter a 10-digit phone number.');
  });

  testWidgets('signup leaves out fields left empty', (tester) async {
    tallPhone(tester);
    Map<String, dynamic>? body;
    await http.runWithClient(() async {
      await fillSignup(tester, dlNo: '', phone: '  ');
    }, () => MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'detail': 'stop here'}, 422);
        }));
    expect(body!.containsKey('dl_no'), isFalse);
    expect(body!.containsKey('phone'), isFalse);
  });

  testWidgets('Account shows both, saves them, and shows the phone as the server kept it', (tester) async {
    tallPhone(tester);
    ApiClient.instance.token = _token;
    Map<String, dynamic>? patched;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: AccountScreen()));
      await tester.pumpAndSettle();
      expect(find.text('20B/UP7820B001234'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Shop phone'), '+91 98390-12345');
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();
      expect(find.text('9839012345'), findsOneWidget);
    }, () => MockClient((req) async {
          if (req.method == 'PATCH') {
            patched = jsonDecode(req.body) as Map<String, dynamic>;
            return _json(_account(dlNo: patched!['dl_no'] as String, phone: '9839012345'));
          }
          return _json(_account(dlNo: '20B/UP7820B001234'));
        }));
    expect(patched!['dl_no'], '20B/UP7820B001234');
    expect(patched!['phone'], '+91 98390-12345');
  });

  testWidgets('the receipt offers the bill, and nudges while a shop detail is missing', (tester) async {
    tallPhone(tester);
    ApiClient.instance.token = _token;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: SaleReceiptScreen(saleId: 5)));
      await tester.pumpAndSettle();
      expect(find.text('Share bill (PDF)'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Share as text'), findsOneWidget);
      expect(find.text('Your drug licence no. and phone are not on your bills.'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pump();
      expect(find.text('Your drug licence no. and phone are not on your bills.'), findsNothing);
    }, () => MockClient((req) async => req.url.path == '/account'
        ? _json(_account(dlNo: '20B/UP7820B001234'))
        : _json(_sale())));
  });

  testWidgets('no nudge once both are set', (tester) async {
    tallPhone(tester);
    ApiClient.instance.token = _token;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: SaleReceiptScreen(saleId: 5)));
      await tester.pumpAndSettle();
      expect(find.text('Share bill (PDF)'), findsOneWidget);
      expect(find.text('Your drug licence no. and phone are not on your bills.'), findsNothing);
    }, () => MockClient((req) async => req.url.path == '/account'
        ? _json(_account(dlNo: '20B/UP7820B001234', phone: '9839012345'))
        : _json(_sale())));
  });
}
