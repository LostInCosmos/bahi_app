import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/product_catalog.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';
import 'package:gst_bill_app/features/sales/presentation/sales_screen.dart';

/// DAS-111 (added 2026-10-25): a sale may ask for more than a batch holds.
/// The shopkeeper sees a note that never reaches the bill, and the sale goes
/// through; the server floors the batch at 0. An expired batch stays blocked.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

MockClient _server(List<Map<String, dynamic>> batches) => MockClient((req) async {
      if (req.url.path == '/inventory/products') {
        return _json([
          {'id': 1, 'name': 'Cetirizine', 'quantity_on_hand': 45, 'mrp': 20},
        ]);
      }
      if (req.url.path == '/inventory/products/1') {
        return _json({'id': 1, 'name': 'Cetirizine', 'total_quantity': 45, 'batches': batches});
      }
      return http.Response('no', 404);
    });

Map<String, dynamic> _batch({int id = 7, double onHand = 45, bool expired = false}) => {
      'id': id,
      'batch_no': 'B$id',
      'expiry_date': expired ? '2024-01-01' : '2028-06-30',
      'quantity_on_hand': onHand,
      'mrp': 20,
      'gst_pct': 12,
      'is_expired': expired,
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = 'h.${base64Url.encode(utf8.encode('{"tenant_id":1}')).replaceAll('=', '')}.s';
  });
  tearDown(() => ApiClient.instance.token = null);

  void tallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> openPicker(WidgetTester tester) async {
    tallPhone(tester);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SalesScreen())));
    await ProductCatalog.instance.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
  }

  group('the note', () {
    test('says how much there is, only when the sale asks for more', () {
      expect(stockNote(10, 45), isNull);
      expect(stockNote(45, 45), isNull);
      expect(stockNote(60, 45), 'Only 45 in inventory. This note will not appear on the bill.');
      expect(stockNote(2, 0), 'None in inventory. This note will not appear on the bill.');
      expect(stockNote(60, null), isNull, reason: 'stock not known: nothing to say');
    });

    test('the review list carries its short form', () {
      CartEntry line(double qty, double? available) =>
          CartEntry(productBatchId: 1, productName: 'X', qty: qty, rate: 20, gstPct: 12, available: available);
      expect(line(60, 45).shortStockNote, 'Only 45 in inventory · not on the bill');
      expect(line(10, 45).shortStockNote, isNull);
      expect(line(1, 0).shortStockNote, 'None in inventory · not on the bill');
    });
  });

  testWidgets('add sheet: more than the batch holds shows the note and still adds', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Qty'), '60');
      await tester.pump();
      expect(find.text('Only 45 in inventory. This note will not appear on the bill.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('View cart · 1 item'), findsOneWidget);
    }, () => _server([_batch()]));
  });

  testWidgets('a product with none in stock can still be opened from the list', (tester) async {
    await http.runWithClient(() async {
      tallPhone(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SalesScreen())));
      await ProductCatalog.instance.refresh();
      await tester.pumpAndSettle();
      final add = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_circle_outline));
      expect(add.onPressed, isNotNull);
    }, () => MockClient((req) async => req.url.path == '/inventory/products'
        ? _json([
            {'id': 1, 'name': 'ORS', 'quantity_on_hand': 0, 'mrp': 22},
          ])
        : http.Response('no', 404)));
  });

  testWidgets('add sheet: a batch with none left can be sold; an expired one cannot', (tester) async {
    await http.runWithClient(() async {
      await openPicker(tester);
      final adds = find.widgetWithText(FilledButton, 'Add');
      expect(tester.widget<FilledButton>(adds.at(0)).onPressed, isNotNull, reason: 'none left: sellable with a note');
      expect(tester.widget<FilledButton>(adds.at(1)).onPressed, isNull, reason: 'expired: blocked');
      expect(find.text('None in inventory. This note will not appear on the bill.'), findsOneWidget);
    }, () => _server([_batch(id: 7, onHand: 0), _batch(id: 8, expired: true)]));
  });

  testWidgets('review: an oversold line shows the short note', (tester) async {
    tallPhone(tester);
    await tester.pumpWidget(MaterialApp(
      home: SaleReviewScreen(cart: [
        CartEntry(productBatchId: 7, productName: 'Cetirizine', batchNo: 'B7', qty: 60, rate: 20, gstPct: 12, available: 45),
      ]),
    ));
    expect(find.text('Only 45 in inventory · not on the bill'), findsOneWidget);
  });

  testWidgets('an older server still refuses, and its answer is shown as before', (tester) async {
    tallPhone(tester);
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: SaleReviewScreen(cart: [
          CartEntry(productBatchId: 7, productName: 'Cetirizine', batchNo: 'B7', qty: 60, rate: 20, gstPct: 12, available: 45),
        ]),
      ));
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();
      expect(find.text('Not enough stock for Cetirizine: requested 60, available 45.'), findsOneWidget);
    }, () => MockClient((req) async => _json({
          'detail': {
            'error': 'insufficient_stock',
            'product_batch_id': 7,
            'product_name': 'Cetirizine',
            'requested': 60,
            'available': 45,
          },
        }, 422)));
  });
}
