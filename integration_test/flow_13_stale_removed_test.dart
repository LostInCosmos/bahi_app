// Flow 13 (DAS-193): a bill removed elsewhere cannot be saved from a screen
// that still shows it.
//
// The server reads this run's photo with a misread grand total
// (tool/e2e/run.sh: flow_outcome `totals`), so the bill waits, flagged. The
// shop opens it to correct it; meanwhile "another phone" discards it (the
// flow does that itself, through the same API and session). Correcting it
// and tapping Revalidate would have saved it again; now the server answers
// bill_removed, the form closes and the card goes, with a note.
import 'dart:convert';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/capture/data/capture_api.dart';
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

void main() {
  e2eFlow('flow_13_stale_removed', 'a bill removed on another phone cannot be saved from an open form', ($, steps) async {
    await startApp($);
    await signIn($);
    await openTab($, 'Capture');

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
    await steps.shot('form-open');

    // Another phone discards this bill while the form is open.
    final res = await ApiClient.instance.get('/invoices/extract');
    final jobs = (jsonDecode(res.body) as Map)['jobs'] as List;
    final newest = (jobs.first as Map)['job_id'] as int;
    await ApiClient.instance.bulkDiscard([newest]);

    // The fix the shop types would make it clean; Revalidate would save it.
    await field($, 'Grand total').scrollTo().enterText('420');
    await $('Revalidate').scrollTo().tap();

    await $('This bill was removed.').waitUntilVisible(timeout: const Duration(seconds: 20));
    expect($('Review & save').exists, isFalse, reason: 'the form closed');
    await steps.shot('removed');
  });
}
