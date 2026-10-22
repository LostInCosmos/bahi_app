// Shared pieces of the end-to-end flows (DAS-109): the seeded shop, starting
// the app against the local server, signing in, moving between tabs, and
// one screenshot per step.
//
// Run by `tool/e2e/run.sh`, never by `flutter test`. Each flow file is one
// `e2eFlow`, and Patrol's orchestrator wipes the app's data before each one,
// so every flow starts as on a fresh install and signs in for itself.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/main.dart';
import 'package:patrol/patrol.dart';

export 'package:flutter/material.dart' hide Notification;
export 'package:flutter_test/flutter_test.dart';
export 'package:patrol/patrol.dart';

/// What `tool/e2e/run.sh` passes as `--dart-define`, read from the server's
/// `.e2e/seed.json`. The defaults match that seed, so a flow can also be run
/// by hand with `patrol test -t integration_test/<flow>_test.dart`.
abstract final class E2E {
  static const baseUrl = String.fromEnvironment('E2E_BASE_URL', defaultValue: 'http://10.0.2.2:8000');
  static const email = String.fromEnvironment('E2E_EMAIL', defaultValue: 'e2e@dastavez.test');
  static const password = String.fromEnvironment('E2E_PASSWORD', defaultValue: 'e2e-test-123');
  static const signupEmail = String.fromEnvironment('E2E_SIGNUP_EMAIL', defaultValue: 'e2e-signup@dastavez.test');
  static const signupShop = String.fromEnvironment('E2E_SIGNUP_SHOP', defaultValue: 'E2E Signup Shop');
  static const product = String.fromEnvironment('E2E_PRODUCT', defaultValue: 'E2E PARACETAMOL 500MG');
  static const productSearch = String.fromEnvironment('E2E_PRODUCT_SEARCH', defaultValue: 'E2E PARA');
  static const vendor = String.fromEnvironment('E2E_VENDOR', defaultValue: 'ACME PHARMA (TEST)');

  /// How long a photographed bill may take to be read and saved. The fake
  /// extractor answers in seconds; the phone itself sets no deadline on a
  /// bill (CLAUDE.md), this is the test's.
  static const billSaved = Duration(seconds: 120);
}

/// Waits are bounded and nothing sleeps: a step either sees its widget
/// within the timeout or fails. `trySettle` is essential — a busy button's
/// spinner or a held request never "settles", and `settle` would time out.
const kE2EConfig = PatrolTesterConfig(
  existsTimeout: Duration(seconds: 20),
  visibleTimeout: Duration(seconds: 20),
  settleTimeout: Duration(seconds: 5),
  settlePolicy: SettlePolicy.trySettle,
  printLogs: true,
);

typedef E2EBody = Future<void> Function(PatrolIntegrationTester $, Steps steps);

/// One flow: `name` is the flow's file stem (`flow_02_photograph`) and prefixes
/// every screenshot of it.
void e2eFlow(String name, String description, E2EBody body) {
  patrolTest(description, config: kE2EConfig, ($) async {
    final steps = Steps($, name);
    await body($, steps);
    await steps.shot('end');
  });
}

/// Numbered screenshots, one per step: `flow_02_photograph-03-crop.png`.
/// `patrol test` collects them from the device after the run (Patrol 4.10+);
/// `run.sh` moves them to the run's folder.
class Steps {
  Steps(this.$, this.flow);
  final PatrolIntegrationTester $;
  final String flow;
  int _n = 0;

  /// Deliberately no `pump()` first: while another app is in front (the
  /// camera, the share sheet) the Flutter activity is paused and never
  /// produces a frame, so a pump here hangs the flow for good. The native
  /// screenshot captures the screen as it is.
  Future<void> shot(String what) async {
    _n++;
    final tag = '$flow-${_n.toString().padLeft(2, '0')}-$what';
    await $.platform.takeNativeScreenshot(tag);
    debugPrint('E2E step $tag');
  }
}

/// Starts the real app pointed at the local server and waits for the login
/// screen. The base URL is written where the app reads it at start, so the
/// login screen's "API base URL" field needs no typing.
Future<void> startApp(PatrolIntegrationTester $) async {
  await ApiClient.instance.setBaseUrl(E2E.baseUrl);
  await $.pumpWidgetAndSettle(const GstBillApp());
  await loginButton($).waitUntilVisible(timeout: const Duration(seconds: 30));
}

/// The login screen's one FilledButton: "Log in", or "Create account" in
/// sign-up mode. (The Log in / Sign up switch above the form is not a button.)
PatrolFinder loginButton(PatrolIntegrationTester $) => $(FilledButton).containing('Log in');
PatrolFinder createAccountButton(PatrolIntegrationTester $) => $(FilledButton).containing('Create account');

/// A text field by its label, so a finder never lands on the label's own
/// `Text` widget (which cannot take text).
PatrolFinder field(PatrolIntegrationTester $, String label) =>
    $(TextField).which<TextField>((t) => t.decoration?.labelText == label);

/// Signs in as the seeded shop and waits for the home screen.
Future<void> signIn(PatrolIntegrationTester $, {String email = E2E.email, String password = E2E.password}) async {
  await field($, 'Email').enterText(email);
  await field($, 'Password').enterText(password);
  await loginButton($).tap();
  await $('New bills').waitUntilVisible(timeout: const Duration(seconds: 30));
}

/// Opens a home tab by its bar label (Capture, Purchases, Inventory, Sell, Sales).
Future<void> openTab(PatrolIntegrationTester $, String label) async {
  await $(NavigationBar).$(label).tap();
}

/// Taps the home app bar's Log out icon.
Future<void> tapLogOut(PatrolIntegrationTester $) async {
  await $(IconButton).which<IconButton>((b) => b.tooltip == 'Log out').tap();
}

/// Dismisses the keyboard if a field left it up (a tab bar under a keyboard
/// is off screen).
Future<void> hideKeyboard(PatrolIntegrationTester $) async {
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await $.pump(const Duration(milliseconds: 300));
}

/// The stock number shown for [product] on the Inventory list ("100 in
/// stock" in the row's chip), once its row is on screen. A row is a Card
/// (Inventory lays its own row out; Sell uses a ListTile inside one).
Future<int> stockShown(PatrolIntegrationTester $, String product) async {
  final chip = $(Card).containing(product).$(find.textContaining(' in stock'));
  await chip.waitUntilVisible(timeout: const Duration(seconds: 30));
  final text = chip.text!;
  return int.parse(text.split(' ').first.replaceAll(',', ''));
}

/// Waits until the Inventory list shows [stock] for [product]: the list is
/// refetched when the tab is opened, so the new number can lag by a request.
Future<void> waitForStock(PatrolIntegrationTester $, String product, int stock) async {
  await $(Card).containing(product).$('$stock in stock').waitUntilVisible(timeout: const Duration(seconds: 30));
}
