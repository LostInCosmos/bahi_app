import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import 'login_screen.dart';

/// Ends this device's session and lands on the login screen with nothing
/// behind it, so Back cannot return to a signed-out screen. Decoded bill
/// images go too (DAS-90), so the next shop's session starts without them.
///
/// The one voluntary sign-out — the home screen's Log out and the
/// update-required screen's both use it. A session the SERVER ended (a 401)
/// goes through `ApiClient.onSessionEnded` in `app/app.dart` instead, which
/// also says why.
Future<void> signOut(BuildContext context) async {
  await ApiClient.instance.logout();
  imageCache.clear();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (_) => false,
  );
}
