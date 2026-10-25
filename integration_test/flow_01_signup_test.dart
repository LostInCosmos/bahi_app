// Flow 1: a new shop signs up and lands on the home screen.
//
// The sign-up email is unused only on a fresh seed: tool/e2e/run.sh resets
// the server before every run, so this flow is not repeatable without that.
import 'e2e/e2e.dart';

void main() {
  e2eFlow('flow_01_signup', 'sign up a new shop and land on home', ($, steps) async {
    await startApp($);
    await steps.shot('login-screen');

    await $('Sign up').tap();
    await field($, 'Shop / tenant name').enterText(E2E.signupShop);
    await field($, 'Email').enterText(E2E.signupEmail);
    await field($, 'Password').enterText(E2E.password);
    // The shop's licence no. and phone, printed on its bills (DAS-121).
    await field($, 'Drug licence no. (optional)').scrollTo().enterText('20B/UP-E2E-0001');
    await field($, 'Shop phone (optional)').scrollTo().enterText('+91 98390 12345');
    await $(const ValueKey('accept-terms')).scrollTo().tap();
    await steps.shot('form-filled');

    // "Create account" is enabled only once the terms are ticked. Below the
    // fold on a phone since the shop fields were added.
    await createAccountButton($).scrollTo().tap();
    await $('New bills').waitUntilVisible(timeout: const Duration(seconds: 30));
    await steps.shot('home');
  });
}
