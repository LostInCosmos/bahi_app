// Flow 11 (DAS-185): a read whose subtotal is blank stays blank on the phone.
//
// The server reads this run's photo with no subtotal and a misread grand total
// (tool/e2e/run.sh: flow_outcome `blank_subtotal`), so the bill is flagged on
// the grand total. Opening it used to turn the blank subtotal into 0, which the
// draft then carried and the check flagged. Now the form shows it blank, and
// once the grand total is put right the bill saves itself with no subtotal.
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/status_filter.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

import 'e2e/e2e.dart';

PatrolFinder _flagged(PatrolIntegrationTester $) => $(find.byElementPredicate((e) {
      final w = e.widget;
      if (w is BatchItemCard) return w.item.status == BatchItemStatus.needsReview;
      if (w.runtimeType.toString() == '_UploadCard') {
        return uploadCategory((w as dynamic).upload as UploadSummary) == 'review';
      }
      return false;
    }, description: 'the flagged bill'));

String _fieldText(PatrolIntegrationTester $, String label) =>
    ($.tester.widget(find.widgetWithText(TextField, label)) as TextField).controller!.text;

void main() {
  e2eFlow('flow_11_blank_subtotal', 'a blank subtotal stays blank, and the bill saves once the total is right',
      ($, steps) async {
    await startApp($);
    await signIn($);
    await openTab($, 'Capture'); // Home lands first (DAS-186)

    if ($('Take photo').exists) {
      await $('Take photo').tap();
    } else {
      await $('Add another').tap();
    }
    if (await $.platform.mobile.isPermissionDialogVisible(timeout: const Duration(seconds: 3))) {
      await $.platform.mobile.grantPermissionWhenInUse();
    }
    await $.platform.mobile.takeCameraPhoto();
    await $('Adjust corners').waitUntilVisible(timeout: const Duration(seconds: 30));
    await $('Confirm this page').tap();

    await _flagged($).waitUntilExists(timeout: E2E.billSaved);
    await _flagged($).first.tap();
    await $('Edit').waitUntilVisible(timeout: const Duration(seconds: 20));
    await $('Edit').tap();
    await $('Review & save').waitUntilVisible(timeout: const Duration(seconds: 20));

    await field($, 'Subtotal').scrollTo();
    expect(_fieldText($, 'Subtotal'), '', reason: 'the blank stays blank, not "0"');
    await steps.shot('blank-subtotal');

    // Revalidate untouched: the draft carries the blank, and nothing new is flagged.
    await $('Revalidate').scrollTo().tap();
    await $(find.textContaining('Still has flagged fields')).waitUntilVisible(timeout: const Duration(seconds: 20));
    expect(_fieldText($, 'Subtotal'), '', reason: "still blank after the server's answer");

    // The real fix: the grand total. Clean, it saves itself (DAS-180).
    await field($, 'Grand total').scrollTo().enterText('420');
    await $('Revalidate').scrollTo().tap();
    for (var i = 0; i < 40 && $('Review & save').exists; i++) {
      await $.pump(const Duration(milliseconds: 500));
    }
    expect($('Review & save').exists, isFalse, reason: 'saved itself');
    await steps.shot('saved');
  });
}
