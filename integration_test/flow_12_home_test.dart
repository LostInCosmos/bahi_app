// Flow 12 (DAS-186): the shop lands on Home; its Running low tile opens
// Inventory with that chip on, and View sales opens the sales history.
//
// The seed has two products at or under five packs (PARACETAMOL 650 TAB,
// 4.5 strips; BECOSULES, 5 bottles), so Running low is never empty here,
// whatever the flows before this one sold.
import 'package:gst_bill_app/features/sales/presentation/sales_history_screen.dart';

import 'e2e/e2e.dart';

void main() {
  e2eFlow('flow_12_home', 'land on Home, open Running low and the sales history from it', ($, steps) async {
    await startApp($);
    await signIn($);

    await $("Today's sales").waitUntilVisible(timeout: const Duration(seconds: 30));
    await steps.shot('home');

    await $(const ValueKey('home-tile-low')).tap();
    await $(find.textContaining('RUNNING LOW')).waitUntilVisible(timeout: const Duration(seconds: 20));
    await $(find.textContaining('BECOSULES')).waitUntilVisible();
    await steps.shot('inventory-running-low');

    await openTab($, 'Home');
    await $(const ValueKey('home-view-sales')).tap();
    await $(SalesHistoryScreen).waitUntilVisible(timeout: const Duration(seconds: 20));
    await steps.shot('sales-history');
  });
}
