// Flow 7: a shopkeeper's corrections to a flagged bill are kept until it is
// saved (DAS-153).
//
// The server reads this run's photos with a misread grand total
// (tool/e2e/run.sh: flow_outcome), so the bill needs review. The corrections
// lived only in the phone's card, which hands over to the shop's list once
// the list shows the bill in the same box (DAS-62) — and the list shows the
// read. Without the fix, reopening the bill shows the original invoice number.
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/models/status_filter.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';

import 'e2e/e2e.dart';

const _edited = 'T-EDITED-E2E';

/// The bill, read and flagged: this phone's card, or once it has handed
/// over, the shop's row.
PatrolFinder _flagged(PatrolIntegrationTester $) => $(find.byElementPredicate((e) {
      final w = e.widget;
      if (w is BatchItemCard) return w.item.status == BatchItemStatus.needsReview;
      if (w.runtimeType.toString() == '_UploadCard') {
        final upload = (w as dynamic).upload as UploadSummary;
        return uploadCategory(upload) == 'review';
      }
      return false;
    }, description: 'the flagged bill'));

PatrolFinder _flaggedCard(PatrolIntegrationTester $) => $(find.byElementPredicate(
    (e) => e.widget is BatchItemCard && (e.widget as BatchItemCard).item.status == BatchItemStatus.needsReview,
    description: "this phone's flagged card"));

/// Opens the bill's review form: its dialog, then Edit.
Future<void> _openForm(PatrolIntegrationTester $) async {
  await _flagged($).first.tap();
  await $('Edit').waitUntilVisible(timeout: const Duration(seconds: 20));
  await $('Edit').tap();
  await $('Review & save').waitUntilVisible(timeout: const Duration(seconds: 20));
}

String _fieldText(PatrolIntegrationTester $, String label) =>
    ($.tester.widget(find.widgetWithText(TextField, label)) as TextField).controller!.text;

void main() {
  e2eFlow('flow_07_corrections', 'correct a flagged bill, leave it, and find the corrections kept', ($, steps) async {
    await startApp($);
    await signIn($);

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
    await steps.shot('flagged');

    // Correct the invoice number; the misread total stays, so the bill is
    // still flagged after Revalidate — the card and the list then agree on the
    // box, and the card hands over.
    await _openForm($);
    await field($, 'Invoice number').scrollTo().enterText(_edited);
    await $('Revalidate').scrollTo().tap();
    await $(find.textContaining('Still has flagged fields')).waitUntilVisible(timeout: const Duration(seconds: 20));
    await steps.shot('corrected');
    await $(BackButton).tap(); // the form's own back arrow
    await hideKeyboard($);

    // Handed over: only the shop's row is left.
    for (var i = 0; i < 60 && _flaggedCard($).exists; i++) {
      await $.pump(const Duration(milliseconds: 500));
    }
    expect(_flaggedCard($).exists, isFalse, reason: 'the card hands over to the shop\'s row');
    await steps.shot('handed-over');

    // Reopened from the shop's list: the corrections, not the read.
    await _openForm($);
    expect(_fieldText($, 'Invoice number'), _edited, reason: 'the corrections must survive the hand-over');
    await steps.shot('reopened');

    // Finish correcting and save: what is saved is the corrections.
    await field($, 'Grand total').scrollTo().enterText('420'); // 400 + 10 + 10
    await $('Revalidate').scrollTo().tap();
    await $(find.textContaining('no issues found')).waitUntilVisible(timeout: const Duration(seconds: 20));
    await $('Save invoice').scrollTo().tap();
    // The saved tick, then the form closes.
    for (var i = 0; i < 40 && $('Review & save').exists; i++) {
      await $.pump(const Duration(milliseconds: 500));
    }
    expect($('Review & save').exists, isFalse, reason: 'saved');
    await openTab($, 'Purchases');
    await $(find.textContaining(_edited)).waitUntilVisible(timeout: const Duration(seconds: 30));
    await steps.shot('saved');
  });
}
