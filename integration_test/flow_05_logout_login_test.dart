// Flow 5: log out, land on the login screen with nothing behind it, and log
// in again.
import 'e2e/e2e.dart';

void main() {
  e2eFlow('flow_05_logout_login', 'log out and log in again', ($, steps) async {
    await startApp($);
    await signIn($);
    await steps.shot('home');

    // The server revokes tokens to the second: a logout within the same
    // second as the login would leave the token valid (Backend, DAS-109).
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await tapLogOut($);
    await loginButton($).waitUntilVisible();
    expect($('New bills').exists, isFalse, reason: 'home must be gone after logging out');
    await steps.shot('logged-out');

    await signIn($);
    await steps.shot('home-again');
  });
}
