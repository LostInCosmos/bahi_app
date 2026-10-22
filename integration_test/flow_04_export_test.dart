// Flow 4: export the purchase register. After the photograph flow the shop
// has one saved bill, so the file is built and Android's share sheet opens;
// on a shop with no bills the app says so and shares nothing.
import 'package:gst_bill_app/core/widgets/busy_button.dart';

import 'e2e/e2e.dart';

void main() {
  e2eFlow('flow_04_export', 'export the purchase register', ($, steps) async {
    await startApp($);
    await signIn($);
    await openTab($, 'Purchases');
    // The list has loaded once the Refresh button is no longer busy.
    await $(BusyOutlinedButton).which<BusyOutlinedButton>((b) => !b.busy).waitUntilExists(timeout: const Duration(seconds: 30));
    final hasBills = $(find.textContaining(E2E.vendor)).exists;
    await steps.shot('purchases');

    await $('Export').tap();
    await $('GSTR2 purchase register').waitUntilVisible();
    await steps.shot('export-sheet');
    await $('GSTR2 purchase register').tap();

    final exportButton = $(BusyFilledButton).which<BusyFilledButton>((b) => b.label == 'Export');
    if (hasBills) {
      // Android's share sheet is native: a screenshot records it and Back
      // dismisses it. The range export says nothing on success (only the
      // folder export counts bills), so success is the Export button coming
      // back from busy with no error line under it.
      await Future<void>.delayed(const Duration(seconds: 3));
      await steps.shot('share-sheet');
      await $.platform.android.pressBack();
      await exportButton.which<BusyFilledButton>((b) => !b.busy).waitUntilExists(timeout: const Duration(seconds: 30));
      expect($(find.textContaining('Export failed')).exists, isFalse, reason: 'the export must not fail');
      expect($(find.textContaining('No bills')).exists, isFalse, reason: 'the shop has a saved bill');
    } else {
      await $('No bills in this range.').waitUntilVisible(timeout: const Duration(seconds: 30));
    }
    await steps.shot('done');
  });
}
