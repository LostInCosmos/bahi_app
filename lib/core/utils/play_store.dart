import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// The app's id on Google Play (DAS-189). Builds 2005 and older were
/// `com.dastavez.bahi`, a different app: Play installs this one beside them.
const kPlayStoreAppId = 'com.dastavez.app';

/// Whether this device can be sent to Google Play at all: Android only.
bool get canOpenPlayStore => debugCanOpenPlayStore ?? Platform.isAndroid;

/// Tests run on the desktop: they say whether there is a Play Store, and
/// what opening it does.
@visibleForTesting
bool? debugCanOpenPlayStore;
@visibleForTesting
Future<bool> Function()? debugOpenPlayStore;

/// Opens this app's Play Store page, in the Play Store app when there is one
/// (`market://`), else in the browser. False when neither could be opened.
/// The listing is closed testing for now (2026-11-14): a shop that is not an
/// opted-in tester sees "not found" there, which the update screens say.
Future<bool> openPlayStore() async {
  final fake = debugOpenPlayStore;
  if (fake != null) return fake();
  try {
    if (await launchUrl(Uri.parse('market://details?id=$kPlayStoreAppId'), mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (_) {
    // No Play Store app: the browser below.
  }
  try {
    return await launchUrl(Uri.parse('https://play.google.com/store/apps/details?id=$kPlayStoreAppId'),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
