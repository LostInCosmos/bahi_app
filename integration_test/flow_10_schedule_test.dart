// Flow 10 (DAS-183): the shop tags a medicine Schedule X on its product page,
// and Inventory's Schedule filter finds it.
//
// The seed tags nothing, so Inventory shows no schedule chip at first. X is
// the code the server added in DAS-183: an older server refuses it, so this
// flow fails there.
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

import 'e2e/e2e.dart';

const _item = 'CETIRIZINE 10MG TAB';

void main() {
  e2eFlow('flow_10_schedule', 'tag a medicine Schedule X, then filter Inventory by it', ($, steps) async {
    await startApp($);
    await signIn($);

    await openTab($, 'Inventory');
    await $(const ValueKey('inventory-search')).enterText(_item);
    await $(Card).containing(_item).waitUntilVisible(timeout: const Duration(seconds: 30));
    // By key: Patrol's own banner carries the test's name, "…Schedule X…".
    expect($(const ValueKey('inventory-schedule-X')).exists, isFalse, reason: 'nothing is tagged yet');
    await steps.shot('untagged');

    await $(Card).containing(_item).tap();
    await $(ProductDetailScreen).waitUntilVisible();
    await $(const ValueKey('product-schedule')).waitUntilVisible(timeout: const Duration(seconds: 20));
    await $(const ValueKey('product-schedule')).$('X').tap();
    await $('Marked Schedule X.').waitUntilVisible(timeout: const Duration(seconds: 20));
    await steps.shot('tagged-x');
    await $.platform.android.pressBack();

    // The list behind the filter was asked again: the chip counts it.
    await $(const ValueKey('inventory-schedule-X')).waitUntilVisible(timeout: const Duration(seconds: 30));
    await $(const ValueKey('inventory-schedule-X')).tap();
    await $(Card).containing(_item).waitUntilVisible();
    await $(find.textContaining('SCHEDULE X')).waitUntilVisible();
    await steps.shot('filtered-x');
  });
}
