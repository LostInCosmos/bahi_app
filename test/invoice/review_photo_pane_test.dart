import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/invoice/models/invoice.dart';
import 'package:gst_bill_app/features/invoice/presentation/review_screen.dart';

/// The bill photo on the review form (DAS-115): pinned above the form, sized
/// by its handle, folded while the keyboard is up, and retried when it fails.
/// The photo itself never loads here — a loaded one is written to the disk
/// cache, which needs a real device — so these drive the pane around it.

Map<String, dynamic> _invoice() => {
      'seller_name': 'ACME',
      'seller_gstin': '',
      'invoice_no': 'A-9',
      'invoice_date': '2026-08-01',
      'line_items': [
        {'product_name': 'Pan 40', 'qty': 2, 'rate': 50, 'gst_pct': 12, 'gross_amount': 100},
      ],
      'totals': {'subtotal': 100, 'total_cgst': 6, 'total_sgst': 6, 'grand_total': 112},
    };

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester) async {
  final result = ExtractionResult.fromJson({
    'invoice': _invoice(),
    'extraction_meta': {'source_image': '8/9.jpg', 'method': 'llm'},
    'issues': [],
  });
  await tester.binding.setSurfaceSize(const Size(390, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: ReviewScreen(result: result)));
  await _settle(tester);
}

double _paneHeight(WidgetTester tester) => tester
    .getSize(find.ancestor(of: find.byTooltip('Hide bill photo'), matching: find.byType(Container)).last)
    .height;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a photo that cannot load says so and is fetched again on a tap', (tester) async {
    var asked = 0;
    final client = MockClient((req) async {
      if (req.url.path.startsWith('/invoices/image/')) asked++;
      return http.Response('not found', 404);
    });
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text("Couldn't load the photo. Tap to retry."), findsOneWidget);
      await tester.tap(find.text("Couldn't load the photo. Tap to retry."));
      await _settle(tester);
      expect(asked, 2);
    }, () => client);
  });

  testWidgets('the handle sets the height, up to half the screen, and a drag past the top folds it', (tester) async {
    final client = MockClient((req) async => http.Response('not found', 404));
    await http.runWithClient(() async {
      await _open(tester);
      final start = _paneHeight(tester);
      final handle = find.bySemanticsLabel('Resize bill photo');

      await tester.drag(handle, const Offset(0, 120));
      await _settle(tester);
      expect(_paneHeight(tester), greaterThan(start));

      await tester.drag(handle, const Offset(0, 2000));
      await _settle(tester);
      final tallest = _paneHeight(tester);
      expect(tallest, lessThanOrEqualTo(800 / 2));

      await tester.drag(handle, const Offset(0, -2000));
      await _settle(tester);
      expect(find.text('Bill photo'), findsOneWidget, reason: 'folded to its strip');
      expect(find.byTooltip('Hide bill photo'), findsNothing);

      await tester.tap(find.text('Bill photo'));
      await _settle(tester);
      expect(find.byTooltip('Hide bill photo'), findsOneWidget);
    }, () => client);
  });

  testWidgets('the photo folds while the keyboard is up, and comes back when it goes', (tester) async {
    final client = MockClient((req) async => http.Response('not found', 404));
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.byTooltip('Hide bill photo'), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await _settle(tester);
      expect(find.text('Bill photo'), findsOneWidget);

      tester.view.resetViewInsets();
      await _settle(tester);
      expect(find.byTooltip('Hide bill photo'), findsOneWidget);
    }, () => client);
  });
}
