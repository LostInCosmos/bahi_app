// Flow 8 (DAS-160): a strip of 10 tablets is sold by the tablet and a bottle
// only whole. Sells 20 tablets of the seeded strip at a tablet's price and
// one bottle, and sees Inventory count the strip in tablets and the bottle in
// packs.
//
// Stock is read from the screen, not assumed, so the flow holds whether or
// not the server was reset since the last run.
import 'e2e/e2e.dart';

const _strip = 'PARACETAMOL 650 TAB';
const _bottle = 'BECOSULES 60 CAPS BOTTLE';

void main() {
  e2eFlow('flow_08_sell_loose', 'sell tablets from a strip and a whole bottle', ($, steps) async {
    await startApp($);
    await signIn($);

    await openTab($, 'Inventory');
    final tabletsBefore = await stockShown($, _strip);
    final bottlesBefore = await stockShown($, _bottle);
    await steps.shot('inventory-strip-before');

    await openTab($, 'Sell');
    await field($, 'Search a medicine to add').enterText('PARACETAMOL 650');
    await $(ListTile).containing(_strip).$(IconButton).tap();
    await $('Available: $tabletsBefore tablets').waitUntilVisible();
    await $('Strip of 10, so 2 strips = 20 tablets').waitUntilVisible();
    await $('10.00').waitUntilVisible(); // MRP ₹100 ÷ 10
    await field($, 'Tablets').enterText('20');
    await steps.shot('strip-tablets');
    await $('Add').tap();

    await field($, 'Search a medicine to add').enterText('BECOSULES');
    await $(ListTile).containing(_bottle).$(IconButton).tap();
    await $("Sold whole only, at the pack's MRP").waitUntilVisible();
    await steps.shot('bottle-whole');
    await $('Add').tap();

    await $(find.textContaining('View cart')).tap();
    await $('Review sale').waitUntilVisible();
    await $('$_strip × 20 tablets').waitUntilVisible();
    await $('$_bottle × 1').waitUntilVisible();
    await steps.shot('review');
    await $('Complete sale').tap();
    await $('Sale complete').waitUntilVisible(timeout: const Duration(seconds: 30));
    await $(find.textContaining('× 20 tablets')).waitUntilVisible();
    await steps.shot('receipt');
    await $('New sale').tap();

    await openTab($, 'Inventory');
    await waitForStock($, _strip, tabletsBefore - 20, unit: 'tablets');
    await waitForStock($, _bottle, bottlesBefore - 1);
    await steps.shot('inventory-after');
  });
}
