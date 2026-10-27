import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/sales/data/sale_bill_pdf.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';

// DAS-150: on Review sale, how the customer paid (Cash preselected, or
// Online), the customer's phone and the prescribing doctor, all optional;
// stored by the server and printed on the bill when given.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

List<CartEntry> _cart() => [CartEntry(productBatchId: 1, productName: 'Dolo 650', qty: 1, rate: 33.6, gstPct: 12)];

void main() {
  setUp(() => ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s');
  tearDown(() => ApiClient.instance.token = null);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1800 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: _cart())));
  }

  testWidgets('a cash sale needs no tap: Cash is preselected and nothing optional is sent', (tester) async {
    Map<String, dynamic>? body;
    await http.runWithClient(() async {
      await open(tester);
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
    }, () => MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'sale_id': 5});
        }));
    expect(body!['payment_mode'], 'cash');
    expect(body!.containsKey('buyer_phone'), isFalse);
    expect(body!.containsKey('doctor_name'), isFalse);
  });

  testWidgets('Online, a phone and a doctor are sent as typed', (tester) async {
    Map<String, dynamic>? body;
    await http.runWithClient(() async {
      await open(tester);
      await tester.tap(find.text('Online'));
      await tester.enterText(find.widgetWithText(TextField, 'Customer phone (optional)'), '98390 12345');
      await tester.enterText(find.widgetWithText(TextField, 'Prescribed by (optional)'), ' R. K. Gupta ');
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
    }, () => MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'sale_id': 5});
        }));
    expect(body!['payment_mode'], 'online');
    expect(body!['buyer_phone'], '98390 12345', reason: 'the server cleans it to 10 digits');
    expect(body!['doctor_name'], 'R. K. Gupta');
  });

  testWidgets("the server's refusal of the phone shows under the phone field", (tester) async {
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Customer phone (optional)'), '12345');
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
      final phone = tester.widget<TextField>(find.widgetWithText(TextField, 'Customer phone (optional)'));
      expect(phone.decoration!.errorText, 'Enter a 10-digit phone number.');
      expect(find.textContaining('Sale failed'), findsNothing);
    }, () => MockClient((req) async => _json({'detail': 'Enter a 10-digit phone number.', 'field': 'buyer_phone'}, 422)));
  });

  testWidgets("a refused doctor's name shows under that field", (tester) async {
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Prescribed by (optional)'), 'Gupta');
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
      final doctor = tester.widget<TextField>(find.widgetWithText(TextField, 'Prescribed by (optional)'));
      expect(doctor.decoration!.errorText, 'Too long.');
    }, () => MockClient((req) async => _json({'detail': 'Too long.', 'field': 'doctor_name'}, 422)));
  });

  test('the sale detail reads the three fields; an older server has none', () {
    final base = {'id': 1, 'sale_no': 'S-1', 'sale_date': '2026-10-27', 'subtotal': 30, 'total_cgst': 1.8, 'total_sgst': 1.8, 'grand_total': 33.6, 'line_items': []};
    final s = SaleDetail.fromJson({...base, 'buyer_phone': '9839012345', 'doctor_name': 'Dr Gupta', 'payment_mode': 'online'});
    expect((s.buyerPhone, s.doctorName, s.paymentMode), ('9839012345', 'Dr Gupta', PaymentMode.online));
    final old = SaleDetail.fromJson(base);
    expect((old.buyerPhone, old.doctorName, old.paymentMode), (null, null, null));
  });

  test('the doctor prints with "Dr" in front unless typed', () {
    expect(doctorLine('R. K. Gupta'), 'Dr R. K. Gupta');
    expect(doctorLine('Dr. Mehta'), 'Dr. Mehta');
    expect(doctorLine('dr sharma'), 'dr sharma');
    expect(doctorLine('Drishti Rao'), 'Dr Drishti Rao', reason: 'a name starting with "Dr" is not a title');
  });
}
