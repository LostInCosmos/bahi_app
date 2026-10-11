import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/invoice/widgets/export_options.dart';

void main() {
  Future<void> open(WidgetTester tester, List<ExportOption> options) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showExportOptions(context, heading: 'Export "Oct"', options: options), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('names what is exported and lists each file on offer', (tester) async {
    await open(tester, [
      ExportOption(title: 'GSTR2', subtitle: 'Excel', run: () async {}),
      ExportOption(title: 'Another file', subtitle: 'PDF', run: () async {}),
    ]);
    expect(find.text('Export "Oct"'), findsOneWidget);
    expect(find.text('GSTR2'), findsOneWidget);
    expect(find.text('Another file'), findsOneWidget);
  });

  testWidgets('choosing a file closes the sheet and runs that file only', (tester) async {
    final ran = <String>[];
    await open(tester, [
      ExportOption(title: 'GSTR2', subtitle: 'Excel', run: () async => ran.add('gstr2')),
      ExportOption(title: 'Another file', subtitle: 'PDF', run: () async => ran.add('other')),
    ]);
    await tester.tap(find.text('Another file'));
    await tester.pumpAndSettle();
    expect(ran, ['other']);
    expect(find.text('GSTR2'), findsNothing);
  });

  testWidgets('closing the sheet runs nothing', (tester) async {
    var ran = 0;
    await open(tester, [ExportOption(title: 'GSTR2', subtitle: 'Excel', run: () async => ran++)]);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(ran, 0);
  });
}
