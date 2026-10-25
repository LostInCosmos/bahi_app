// Flow 2: photograph a bill through the emulator's camera and see it saved
// as a purchase.
//
// The camera is Android's own camera app (image_picker opens it), so the
// shutter and the tick are tapped natively by Patrol; the image it shows is
// what tool/e2e/run.sh booted the emulator with. The local server reads the
// photo with the fake extractor pinned to a clean bill (Backend, DAS-109),
// and a clean bill auto-saves (ADR-018), so no save button is tapped here.
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';
import 'package:gst_bill_app/features/capture/widgets/upload_history.dart';

import 'e2e/e2e.dart';

void main() {
  e2eFlow('flow_02_photograph', 'photograph a bill and see the saved purchase', ($, steps) async {
    await startApp($);
    await signIn($);
    await steps.shot('home');

    // A fresh shop shows the empty state's "Take photo"; a shop with bills
    // has the bottom bar's "Add another" (the camera) instead.
    if ($('Take photo').exists) {
      await $('Take photo').tap();
    } else {
      await $('Add another').tap();
    }
    // The camera app may ask for a permission of its own the first time.
    if (await $.platform.mobile.isPermissionDialogVisible(timeout: const Duration(seconds: 3))) {
      await $.platform.mobile.grantPermissionWhenInUse();
    }
    await steps.shot('camera');
    await $.platform.mobile.takeCameraPhoto();

    await $('Adjust corners').waitUntilVisible(timeout: const Duration(seconds: 30));
    await steps.shot('crop');
    await $('Confirm this page').tap();

    // Uploaded, read and saved. Either this phone's card says so (its badge is
    // an icon), or the card has already been handed over to the shop's list
    // (DAS-62), whose row says "Saved" — which comes first is a race.
    final savedCard = $(find.byElementPredicate((e) {
      final w = e.widget;
      if (w is BatchItemCard) return w.item.status == BatchItemStatus.saved;
      return w is Text && w.data == 'Saved' && e.findAncestorWidgetOfExactType<UploadHistory>() != null;
    }, description: 'a saved bill card'));
    await steps.shot('uploading');
    await savedCard.waitUntilExists(timeout: E2E.billSaved);
    await steps.shot('saved');

    await openTab($, 'Purchases');
    await $(find.textContaining(E2E.vendor)).waitUntilVisible(timeout: const Duration(seconds: 30));
    await steps.shot('purchases');
  });
}
