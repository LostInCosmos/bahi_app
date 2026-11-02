import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/voice/models/voice.dart';
import 'package:gst_bill_app/features/voice/presentation/voice_order_review_screen.dart';

/// Quality pass: the voice review screen tells the truth about its draft.
/// Cancel leaves only once the server has cancelled; Confirm waits for a
/// line change still being sent; a change typed over one in flight says so
/// instead of vanishing.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _order({double qty = 2}) => {
      'id': 1,
      'transcript': 'do dolo',
      'status': 'draft',
      'item_count_heard': 1,
      'total_amount': 40,
      'lines': [
        {
          'id': 10,
          'raw_phrase': 'do dolo',
          'product_id': 5,
          'product_name': 'Dolo 650',
          'quantity': qty,
          'unit': 'strip',
          'mrp': 20,
          'unit_price': 20,
          'line_total': qty * 20,
          'status': 'resolved',
        },
      ],
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
  });
  tearDown(() => ApiClient.instance.token = null);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => VoiceOrderReviewScreen(order: VoiceOrder.fromJson(_order())))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Cancel that fails keeps the screen and says why; a draft already closed just leaves', (tester) async {
    var status = 500;
    var cancels = 0;
    await http.runWithClient(() async {
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Could not cancel: Server error (500)'), findsOneWidget);
      expect(find.byType(VoiceOrderReviewScreen), findsOneWidget, reason: 'the order is still open on the server');

      status = 409;
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(VoiceOrderReviewScreen), findsNothing);
    }, () => MockClient((req) async {
          if (req.url.path == '/voice-orders/1/cancel') {
            cancels++;
            return status == 409 ? _json({'detail': 'already confirmed'}, 409) : http.Response('boom', status);
          }
          return http.Response('no', 404);
        }));
    expect(cancels, 2);
  });

  testWidgets('Confirm is off while a line change is in flight, and a second change is told to wait', (tester) async {
    final held = Completer<http.Response>();
    await http.runWithClient(() async {
      await open(tester);
      final qty = find.widgetWithText(TextField, '2');
      expect(qty, findsOneWidget);
      await tester.enterText(qty, '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm sale')).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextField, '3'), '4');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Still saving the last change. Try again in a moment.'), findsOneWidget);

      held.complete(_json(_order(qty: 3)));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm sale')).onPressed, isNotNull);
    }, () => MockClient((req) {
          if (req.url.path == '/voice-orders/1/lines/10' && req.method == 'PATCH') return held.future;
          return Future.value(http.Response('no', 404));
        }));
  });
}
