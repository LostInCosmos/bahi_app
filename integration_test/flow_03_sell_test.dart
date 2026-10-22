// Flow 3: sell two units of the seeded product by typing, and see the stock
// fall by two in Inventory.
//
// The stock before the sale is read from the screen, not assumed, so the
// flow holds whether or not the server was reset since the last sale.
import 'e2e/e2e.dart';

void main() {
  e2eFlow('flow_03_sell', 'sell by typing and see the stock change', ($, steps) async {
    await startApp($);
    await signIn($);

    await openTab($, 'Inventory');
    final before = await stockShown($, E2E.product);
    await steps.shot('inventory-before');

    await openTab($, 'Sell');
    await field($, 'Search a medicine to add').enterText(E2E.productSearch);
    await steps.shot('search');
    await $(ListTile).containing(E2E.product).$(IconButton).tap();
    await field($, 'Qty').enterText('2');
    await steps.shot('batch');
    await $('Add').tap();
    await $(find.textContaining('View cart')).tap();
    await $('Review sale').waitUntilVisible();
    await steps.shot('review');
    await $('Complete sale').tap();
    await $('Sale complete').waitUntilVisible(timeout: const Duration(seconds: 30));
    await steps.shot('receipt');
    await $('New sale').tap(); // back to the Sell tab

    await openTab($, 'Inventory');
    await waitForStock($, E2E.product, before - 2);
    await steps.shot('inventory-after');
  });
}
