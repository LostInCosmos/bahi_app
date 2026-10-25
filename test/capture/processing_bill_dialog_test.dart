import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/widgets/processing_bill_dialog.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';

/// The dialog for a bill in Processing (DAS-115) follows its bill while open:
/// Edit arrives when the read finishes flagged, and it closes once the bill
/// leaves Processing.

InvoiceData _invoice() => InvoiceData.fromJson({
      'seller_name': 'ACME',
      'seller_gstin': '',
      'invoice_no': 'A-9',
      'invoice_date': '2026-08-01',
      'line_items': [
        {'product_name': 'Pan 40', 'qty': 2, 'rate': 50, 'gst_pct': 12, 'gross_amount': 100},
      ],
      'totals': {'subtotal': 100, 'total_cgst': 6, 'total_sgst': 6, 'grand_total': 112},
    });

void main() {
  late ValueNotifier<int> changes;
  late ProcessingBillView current;
  ProcessingBillAction? answer;
  var closed = false;

  Future<void> open(WidgetTester tester) async {
    changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    answer = null;
    closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await showProcessingBillDialog(context,
                label: 'Bill 12', view: () => current, changes: changes);
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('while reading: Discard only; Edit arrives when the read finishes flagged', (tester) async {
    current = const ProcessingBillView();
    await open(tester);
    expect(find.text('This bill is still being read.'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);

    current = ProcessingBillView(invoice: _invoice());
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.text('Bill is already processed'), findsOneWidget);
    expect(find.text('ACME'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(answer, ProcessingBillAction.edit);
  });

  testWidgets('closes by itself when the bill leaves Processing', (tester) async {
    current = const ProcessingBillView();
    await open(tester);
    current = const ProcessingBillView(inProcessing: false);
    changes.value++;
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(answer, isNull);
    expect(find.text('This bill is still being read.'), findsNothing);
  });

  testWidgets('the cross dismisses it with no answer', (tester) async {
    current = const ProcessingBillView();
    await open(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(answer, isNull);
  });
}
