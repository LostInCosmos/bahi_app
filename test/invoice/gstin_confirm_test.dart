import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/presentation/gstin_confirm.dart';

// The GSTIN confirmation is shared by both save paths — the review screen and
// the one-tap confirm on the capture grid. The grid path was missing it and
// showed the server's raw JSON instead; these pin what both now share.

const _known = VendorHint(
  needsConfirmation: true,
  vendorKnown: true,
  verified: false,
  vendorId: 16,
  gstin: '09ASSPG4908P1ZW',
  vendorName: 'V.S. MEDICOSE',
);

Future<String?> _open(WidgetTester tester, VendorHint hint) async {
  String? result = 'not closed';
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => result = await showGstinConfirmDialog(context, hint),
        child: const Text('save'),
      ),
    ),
  ));
  await tester.tap(find.text('save'));
  await tester.pumpAndSettle();
  return Future.value(result);
}

void main() {
  testWidgets('is pre-filled, so the usual answer is one tap on Submit', (tester) async {
    String? answer = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await showGstinConfirmDialog(context, _known),
          child: const Text('save'),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();

    expect(find.text('09ASSPG4908P1ZW'), findsOneWidget);
    expect(find.textContaining('V.S. MEDICOSE'), findsOneWidget);

    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(answer, '09ASSPG4908P1ZW');
  });

  testWidgets('Cancel returns null — nothing is saved, nothing is failed', (tester) async {
    String? answer = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await showGstinConfirmDialog(context, _known),
          child: const Text('save'),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer, isNull);
  });

  testWidgets('a malformed GSTIN cannot be submitted', (tester) async {
    await _open(tester, _known);
    await tester.enterText(find.byType(TextField), '09ABC');
    await tester.pump();

    final submit = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit'));
    expect(submit.onPressed, isNull);
    expect(find.text('Needs 15 characters in the GSTIN format'), findsOneWidget);
  });

  testWidgets('changing a known supplier\'s GSTIN warns that it will be corrected', (tester) async {
    await _open(tester, _known);
    expect(find.textContaining('correct the supplier'), findsNothing);

    await tester.enterText(find.byType(TextField), '09ASSPG4908P1Z9');
    await tester.pump();
    expect(find.textContaining('correct the supplier'), findsOneWidget);
  });

  testWidgets('a new supplier is worded as new and gets no correction warning', (tester) async {
    const fresh = VendorHint(
      needsConfirmation: true, vendorKnown: false, verified: false,
      vendorId: null, gstin: '09AVJPT2839H1Z2', vendorName: 'NANCY AGENCY',
    );
    await _open(tester, fresh);
    expect(find.text('New supplier'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '09AVJPT2839H1Z9');
    await tester.pump();
    expect(find.textContaining('correct the supplier'), findsNothing);
  });
}
