import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/sales/models/sale.dart';
import 'package:gst_bill_app/features/sales/models/sale_totals.dart';
import 'package:gst_bill_app/features/sales/presentation/sale_review_screen.dart';

/// DAS-111, added 2026-10-25: a line on the review screen can be edited —
/// qty, price and its own discount — by the rules of the sheet that added it.

List<CartEntry> _cart() => [
      CartEntry(productBatchId: 1, productName: 'Dolo', batchNo: 'B12', qty: 2, rate: 20, gstPct: 12, available: 100),
      CartEntry(
        productBatchId: 2,
        productName: 'Cetirizine',
        batchNo: 'C7',
        qty: 10,
        rate: 20,
        gstPct: 12,
        discount: const Discount(DiscountKind.percentage, 10),
        available: 50,
      ),
    ];

void main() {
  void tallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<List<CartEntry>> open(WidgetTester tester) async {
    tallPhone(tester);
    final cart = _cart();
    await tester.pumpWidget(MaterialApp(home: SaleReviewScreen(cart: cart)));
    return cart;
  }

  Future<void> editLine(WidgetTester tester, int index) async {
    await tester.tap(find.byTooltip('Edit').at(index));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);
  FilledButton saveButton(WidgetTester tester) => tester.widget(find.widgetWithText(FilledButton, 'Save'));

  testWidgets('the sheet opens with the line as it is, and Save changes it and the total', (tester) async {
    final cart = await open(tester);
    await editLine(tester, 1);
    expect(find.text('Batch C7 · 50 in stock'), findsOneWidget);
    expect(tester.widget<TextField>(field('Qty')).controller!.text, '10');
    expect(tester.widget<TextField>(field('Discount on this item')).controller!.text, '10');

    await tester.enterText(field('Qty'), '5');
    await tester.pump();
    expect(find.text('Line total ₹90.00  (₹10.00 off)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Cetirizine × 5'), findsOneWidget);
    expect(cart[1].qty, 5);
    expect(cart[1].discount!.value, 10, reason: 'the discount it had is kept');
    expect(find.text('₹130.00'), findsOneWidget, reason: 'total: 40 + 90');
  });

  testWidgets('tapping the line itself opens the editor too', (tester) async {
    await open(tester);
    await tester.tap(find.text('Dolo × 2'));
    await tester.pumpAndSettle();
    expect(find.text('Batch B12 · 100 in stock'), findsOneWidget);
  });

  testWidgets('more than the stock it was added from is allowed, with a note; none is refused', (tester) async {
    await open(tester);
    await editLine(tester, 1);
    await tester.enterText(field('Qty'), '60');
    await tester.pump();
    expect(find.text('Only 50 in inventory. This note will not appear on the bill.'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNotNull, reason: 'a note, not a refusal (DAS-111)');

    await tester.enterText(field('Qty'), '0');
    await tester.pump();
    expect(find.text('Enter a quantity above 0'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('no price is refused, as when adding', (tester) async {
    await open(tester);
    await editLine(tester, 0);
    await tester.enterText(field('Price (incl. GST)'), '0');
    await tester.pump();
    expect(find.text('Enter a price above ₹0'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('a discount bigger than the line is refused', (tester) async {
    await open(tester);
    await editLine(tester, 0);
    await tester.tap(find.text('₹').last);
    await tester.enterText(field('Discount on this item'), '50');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('Cancel changes nothing; the whole-sale discount and buyer survive an edit', (tester) async {
    final cart = await open(tester);
    await tester.enterText(field('Buyer name (optional)'), 'Ravi');
    await tester.enterText(field('Discount on whole sale'), '5');
    await tester.pump();

    await editLine(tester, 0);
    await tester.enterText(field('Qty'), '7');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(cart[0].qty, 2);

    await editLine(tester, 0);
    await tester.enterText(field('Qty'), '3');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(cart[0].qty, 3);
    expect(find.text('Ravi'), findsOneWidget);
    expect(tester.widget<TextField>(field('Discount on whole sale')).controller!.text, '5');
  });

  test('an edited line keeps its batch, product and the stock it was added from', () {
    final line = _cart()[1].edited(qty: 3, rate: 18, discount: null);
    expect((line.productBatchId, line.productName, line.batchNo, line.gstPct, line.available), (2, 'Cetirizine', 'C7', 12.0, 50.0));
    expect((line.qty, line.rate, line.discount), (3.0, 18.0, null));
  });
}
