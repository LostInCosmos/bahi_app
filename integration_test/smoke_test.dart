// A toolchain check, not a flow: the app starts on the emulator and shows
// the login screen. Run first whenever the Android build or Patrol changes.
import 'package:flutter_test/flutter_test.dart';
import 'package:gst_bill_app/main.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest('the app starts and shows the login screen', ($) async {
    await $.pumpWidgetAndSettle(const GstBillApp());
    await $('Log in').waitUntilVisible();
    expect($('Email'), findsOneWidget);
  });
}
