import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps a folder of shop data out of the owner's iCloud backup (DAS-135).
///
/// iOS backs up everything in the app's container except `Library/Caches`
/// and `tmp`, which it may purge. Bill photos waiting to upload and the
/// capture batch cannot live there (they would be lost), so they sit in
/// Application Support with this flag on their folder instead. Apple calls
/// the flag guidance rather than a guarantee, and some file operations reset
/// it, so it is set again every time the folder is first used in a run.
///
/// Android needs nothing: backup is off for the whole app
/// (`android:allowBackup="false"`). Never throws: a folder that could not be
/// marked is still a working folder.
const _channel = MethodChannel('dastavez/backup');

Future<void> excludeFromBackup(Directory dir) async {
  if (!Platform.isIOS) return;
  try {
    await _channel.invokeMethod<bool>('exclude', dir.path);
  } catch (_) {
    // marked again on the next run
  }
}
