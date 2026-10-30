// Flow 6: a bill photographed inside a folder stays in that folder (DAS-151).
//
// Reported from production: bills uploaded inside a folder showed at Home,
// and the shopkeeper moved each one back by hand. The upload carried no
// folder, so the server filed it at Home (and its clean read auto-saved
// there), and the phone's card handed over to that row. This flow fails on
// a build without the fix: the saved row turns up at Home.
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';
import 'package:gst_bill_app/features/capture/widgets/upload_history.dart';

import 'e2e/e2e.dart';

const _folder = 'E2E Folder';

/// Opens the folder's tile from Home and waits until the screen is inside it
/// (its back arrow shows). A tap while the New folder dialog is still closing
/// can be lost, so it is tried again.
Future<void> openFolder(PatrolIntegrationTester $) async {
  final inside = $(IconButton).which<IconButton>((b) => b.tooltip == 'Up one level');
  for (var i = 0; i < 3 && !inside.exists; i++) {
    await $(_folder).waitUntilVisible(timeout: const Duration(seconds: 15));
    await $(_folder).tap();
    for (var j = 0; j < 10 && !inside.exists; j++) {
      await $.pump(const Duration(milliseconds: 300));
    }
  }
  await inside.waitUntilVisible(timeout: const Duration(seconds: 5));
}

void main() {
  e2eFlow('flow_06_folder_upload', 'photograph a bill inside a folder and find it only there', ($, steps) async {
    await startApp($);
    await signIn($);

    // Bills an earlier flow saved at Home stay there; this one must not join
    // them. Counted once Home's list has had time to answer.
    final savedRow = $(find.byElementPredicate(
        (e) => e.widget is Text && (e.widget as Text).data == 'Saved' && e.findAncestorWidgetOfExactType<UploadHistory>() != null,
        description: 'a saved row of the shop\'s list'));
    for (var i = 0; i < 10; i++) {
      await $.pump(const Duration(milliseconds: 500));
    }
    final savedAtHome = savedRow.evaluate().length;

    await $(IconButton).which<IconButton>((b) => b.tooltip == 'New folder').tap();
    await field($, 'Folder name').enterText(_folder);
    await $(FilledButton).containing('Save').tap();
    await openFolder($);
    await steps.shot('in-folder');

    // An empty folder shows the empty state's "Take photo".
    await $('Take photo').waitUntilVisible(timeout: const Duration(seconds: 15));
    await $('Take photo').tap();
    if (await $.platform.mobile.isPermissionDialogVisible(timeout: const Duration(seconds: 3))) {
      await $.platform.mobile.grantPermissionWhenInUse();
    }
    await $.platform.mobile.takeCameraPhoto();
    await $('Adjust corners').waitUntilVisible(timeout: const Duration(seconds: 30));
    await $('Confirm this page').tap();

    // Read and saved (the fake extractor's clean bill auto-saves). Then the
    // card hands over to the shop's list — which must hold it in this folder.
    final savedCard = $(find.byElementPredicate((e) {
      final w = e.widget;
      return w is BatchItemCard && w.item.status == BatchItemStatus.saved;
    }, description: 'this phone\'s saved card'));
    await $(find.byElementPredicate((e) => savedCard.evaluate().contains(e) || savedRow.evaluate().contains(e),
            description: 'the bill, saved'))
        .waitUntilExists(timeout: E2E.billSaved);
    await steps.shot('saved-in-folder');
    // Here the card hands over to the folder's row at once on a server that
    // takes the upload's folder. On one that does not, the row is listed at
    // Home, so the card stays here until Home's list shows the row and the
    // phone moves it (DAS-151) — either way the bill is in this folder.

    // Home: the folder tile counts it, and Home itself has no bill.
    await $('Home').tap();
    await $('1 bill').waitUntilVisible(timeout: const Duration(seconds: 20));
    await steps.shot('home');
    // Give the Home list time to answer (and a wrong hand-over time to show).
    for (var i = 0; i < 10; i++) {
      await $.pump(const Duration(milliseconds: 500));
    }
    expect(savedRow.evaluate().length, savedAtHome, reason: 'a bill added in a folder must not show at Home');

    // And it is in the folder, as the server's row: the card has handed over.
    await openFolder($);
    await savedRow.waitUntilExists(timeout: const Duration(seconds: 20));
    expect(savedCard.exists, isFalse, reason: 'the card handed over to the folder\'s row');
    await steps.shot('back-in-folder');
  });
}
