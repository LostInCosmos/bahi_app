// Flow 9 (DAS-172): an item the shop does not have yet is added from the Sell
// tab with its name, MRP and GST, billed at once from 0 stock (the sale is an
// oversell, DAS-111, and the stock stays at 0), and the shop then corrects
// its stock count from the product page.
//
// The item is created by the flow itself, so no seed is needed; the server
// is reset before every run, so the name is new each time.
import 'package:gst_bill_app/features/inventory/presentation/product_detail_screen.dart';

import 'e2e/e2e.dart';

const _item = 'ZINCOVIT DROPS';

void main() {
  e2eFlow('flow_09_sell_unstocked', 'bill an item not in stock, then correct its stock count', ($, steps) async {
    await startApp($);
    await signIn($);

    await openTab($, 'Sell');
    await field($, 'Search a medicine to add').enterText(_item);
    await $('No products found').waitUntilVisible();
    await steps.shot('not-found');
    await $("Can't find it? Add as new product").tap();
    await $('Add new product').waitUntilVisible();
    await field($, 'MRP').enterText('90');
    await field($, 'GST %').enterText('12');
    await steps.shot('add-new-product');
    await $('Create & continue').tap();

    // Its batch picker opens at once: none in stock, the MRP as the price.
    await $('Available: 0').waitUntilVisible(timeout: const Duration(seconds: 30));
    await $('90.00').waitUntilVisible();
    await steps.shot('picker-zero-stock');
    await $('Add').tap();
    await hideKeyboard($);
    await $(find.textContaining('View cart')).tap();
    await $('Review sale').waitUntilVisible();
    await $(find.textContaining('$_item × 1')).waitUntilVisible();
    await $(find.textContaining('None in inventory')).waitUntilVisible();
    await steps.shot('review-none-in-inventory');
    await $('Complete sale').tap();
    await $('Sale complete').waitUntilVisible(timeout: const Duration(seconds: 30));
    await $(find.textContaining('$_item × 1')).waitUntilVisible();
    await steps.shot('receipt');
    await $('New sale').tap();

    // Stock stayed at 0, never negative.
    await openTab($, 'Inventory');
    await $(const ValueKey('inventory-search')).enterText(_item);
    await waitForStock($, _item, 0);
    await steps.shot('inventory-zero');

    // The shop corrects the count from the product page.
    await $(Card).containing(_item).tap();
    await $(ProductDetailScreen).waitUntilVisible();
    await $('Edit stock').waitUntilVisible(timeout: const Duration(seconds: 20));
    await $('Edit stock').tap();
    await field($, 'Packs in stock').enterText('5');
    await steps.shot('edit-stock');
    await $('Save').tap();
    await $('Stock corrections').waitUntilVisible(timeout: const Duration(seconds: 20));
    await $('0 → 5').waitUntilVisible();
    await steps.shot('stock-corrected');
    await $.platform.android.pressBack();

    await waitForStock($, _item, 5);
    await steps.shot('inventory-five');
  });
}
