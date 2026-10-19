import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/disk/bill_image_cache.dart';
import '../../../core/disk/pending_photo_store.dart';
import '../../capture/data/batch_store.dart';
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

/// Removes everything this device holds for shop [tenantId] — the capture
/// batch, photos not yet uploaded and cached bill images — because the
/// account was deleted (R1, 2026-10-19). A plain log-out keeps all of it for
/// the next sign-in; this is the one path that does not. Never throws.
Future<void> forgetShopOnDevice(int tenantId) async {
  try {
    await BatchStore.forTenant(tenantId).save(const []);
  } catch (_) {
    // the batch is keyed by shop; a stale one is never shown to another
  }
  await PendingPhotoStore.deleteOrphans(tenantId, const {});
  await BillImageCache.forgetShop(tenantId);
}
