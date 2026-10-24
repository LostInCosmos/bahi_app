import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

/// DAS-111: a shop can correct a batch's MRP from the product's batch list.
/// The Edit button exists only when the server says it can take an edit (it
/// sends `mrp_edited`); an old server's list is unchanged.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Server {
  final bool canEdit;
  final double? mrp;
  final List<Map<String, dynamic>> patches = [];
  Map<String, dynamic>? failWith;
  int? failStatus;

  _Server({this.canEdit = true, this.mrp = 100});

  MockClient get client => MockClient((req) async {
        if (req.url.path == '/inventory/products/1') {
          return _json({
            'id': 1,
            'name': 'Paracetamol 500mg',
            'total_quantity': 30,
            'batches': [
              {
                'id': 7,
                'batch_no': 'B12',
                'expiry_date': '2027-03-01',
                'quantity_on_hand': 30,
                'mrp': mrp,
                'gst_pct': 12,
                'is_expired': false,
                'net_rate': 72.0,
                'vendor_name': 'Sharma Pharma',
                'invoice_no': '4471',
                if (canEdit) 'mrp_edited': false,
              },
            ],
          });
        }
        if (req.url.path == '/inventory/batches/7/mrp' && req.method == 'PATCH') {
          patches.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (failStatus != null) return _json(failWith ?? {'detail': 'no'}, failStatus!);
          return _json({
            'batches': [
              {'id': 7, 'mrp': patches.last['mrp'], 'mrp_edited': true},
            ],
          });
        }
        if (req.url.path == '/inventory/products') return _json([]);
        return http.Response('no', 404);
      });
}

void main() {
  setUp(() => ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s');
  tearDown(() => ApiClient.instance.token = null);

  Future<void> open(WidgetTester tester, _Server server, Future<void> Function() body) =>
      http.runWithClient(() async {
        tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(const MaterialApp(home: ProductDetailScreen(productId: 1)));
        await tester.pumpAndSettle();
        await body();
      }, () => server.client);

  testWidgets('an old server (no mrp_edited): no Edit button, the MRP shows as before', (tester) async {
    await open(tester, _Server(canEdit: false), () async {
      expect(find.text('MRP: ₹100.00'), findsOneWidget);
      expect(find.text('Edit MRP'), findsNothing);
    });
  });

  testWidgets('a batch with no MRP says so and offers Add MRP; saving shows it, marked edited', (tester) async {
    final server = _Server(mrp: null);
    await open(tester, server, () async {
      expect(find.text('MRP: not set'), findsOneWidget);
      await tester.tap(find.text('Add MRP'));
      await tester.pumpAndSettle();
      expect(find.text('Paracetamol 500mg · Batch B12 · Sharma Pharma · Invoice 4471'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'MRP (incl. GST)'), '99.50');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(server.patches, [
        {'mrp': 99.5}
      ]);
      expect(find.text('MRP: ₹99.50'), findsOneWidget);
      expect(find.text('edited'), findsOneWidget);
      expect(find.text('MRP: not set'), findsNothing);
    });
  });

  testWidgets('an MRP of 0 or more than ₹10,00,000 is refused before any request', (tester) async {
    final server = _Server();
    await open(tester, server, () async {
      await tester.tap(find.text('Edit MRP'));
      await tester.pumpAndSettle();
      for (final bad in ['0', '', '2000000', 'abc']) {
        await tester.enterText(find.widgetWithText(TextField, 'MRP (incl. GST)'), bad);
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Enter an MRP above ₹0'), findsOneWidget, reason: bad);
      }
      expect(server.patches, isEmpty);
    });
  });

  testWidgets('below what was paid: a warning first, and Save anyway goes through', (tester) async {
    final server = _Server();
    await open(tester, server, () async {
      await tester.tap(find.text('Edit MRP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'MRP (incl. GST)'), '60');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('This is below what you paid (net rate ₹72.00).'), findsOneWidget);
      expect(server.patches, isEmpty, reason: 'nothing sent on the first press');
      await tester.tap(find.widgetWithText(FilledButton, 'Save anyway'));
      await tester.pumpAndSettle();
      expect(server.patches, [
        {'mrp': 60.0}
      ]);
      expect(find.text('MRP: ₹60.00'), findsOneWidget);
    });
  });

  testWidgets('the server refusing the MRP is said in words, and the sheet stays open', (tester) async {
    final server = _Server()
      ..failStatus = 422
      ..failWith = {'detail': {'error': 'bad_mrp'}};
    await open(tester, server, () async {
      await tester.tap(find.text('Edit MRP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'MRP (incl. GST)'), '120');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('That MRP is not allowed. Enter an amount above ₹0.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget, reason: 'the sheet is still up');
      expect(find.text('MRP: ₹100.00'), findsOneWidget, reason: 'and the card behind it is unchanged');
    });
  });
}
