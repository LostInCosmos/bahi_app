import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../../core/disk/backup_exclusion.dart';
import '../../../core/disk/pending_photo_store.dart';
import '../models/batch_item.dart';

/// Saves and restores the capture screen's in-progress batch, so it survives
/// logout, the app being killed, and app updates.
///
/// One batch per shop, under `bahi_batch_<tenantId>` (the key name predates
/// the rename and is kept so existing saved batches still load). The shop is
/// fixed when the store is created — not re-read at every save — so a screen
/// still finishing work after a logout can never write its bills under
/// whichever shop signs in next.
///
/// SharedPreferences and the pending-photo folder both live in app-private
/// storage that an update keeps and only an uninstall removes.
///
/// On iOS the batch is a file instead (DAS-135): `UserDefaults` is one plist
/// that iCloud backs up whole, so a shop's bill reads and supplier names went
/// into the owner's personal backup. The file sits in Application Support in
/// a folder excluded from backup, written beside and renamed over, so a kill
/// mid-write leaves the old batch, never half of one. A batch an older build
/// left in UserDefaults is moved to the file the first time it is read.
/// Android keeps SharedPreferences: backup is off there, and its plugin
/// commits each write before returning.
class BatchStore {
  final int tenantId;

  BatchStore._(this.tenantId);

  /// Null when nobody is signed in.
  static BatchStore? forCurrentUser() {
    final tid = ApiClient.instance.tenantId;
    return tid == null ? null : BatchStore._(tid);
  }

  /// A given shop's store — for forgetting it after its account is deleted.
  static BatchStore forTenant(int tenantId) => BatchStore._(tenantId);

  String get _key => 'bahi_batch_$tenantId';

  /// Whether the batch is a file (iOS) rather than a preference. A test sets it.
  @visibleForTesting
  static bool? debugUseFile;
  static bool get _useFile => debugUseFile ?? Platform.isIOS;

  static Directory? _dir;

  static Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/capture_batch');
    if (!await dir.exists()) await dir.create(recursive: true);
    await excludeFromBackup(dir);
    return _dir = dir;
  }

  /// Forgets the folder, for a test that changes it.
  @visibleForTesting
  static void debugResetDirectory() => _dir = null;

  Future<File> _file() async => File('${(await _directory()).path}/batch_$tenantId.json');

  Future<void> save(List<BatchItem> items) async {
    final serializable = items.where((i) => i.isPersistable).map((i) => i.toJson()).toList();
    if (_useFile) {
      final file = await _file();
      if (serializable.isEmpty) {
        if (await file.exists()) await file.delete();
      } else {
        final temp = File('${file.path}.part');
        await temp.writeAsString(jsonEncode(serializable), flush: true);
        await temp.rename(file.path);
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (serializable.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode(serializable));
    }
  }

  /// The stored batch as written, or null. On iOS, a batch still in
  /// UserDefaults from an older build is moved to the file here.
  Future<String?> _readRaw() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_useFile) return prefs.getString(_key);
    final file = await _file();
    if (await file.exists()) return file.readAsString();
    final legacy = prefs.getString(_key);
    if (legacy != null) {
      final temp = File('${file.path}.part');
      await temp.writeAsString(legacy, flush: true);
      await temp.rename(file.path);
      await prefs.remove(_key);
    }
    return legacy;
  }

  /// The saved batch, in order, plus any photo on the device that the batch
  /// does not mention, brought back as a bill waiting to be cropped (DAS-135).
  ///
  /// Such a photo used to be deleted as an orphan. But a photo is written
  /// to disk before the batch that names it, and shared_preferences does not
  /// promise a write has reached disk when it returns (its README; iOS
  /// flushes UserDefaults lazily) — so a kill in that gap left the only copy
  /// of a bill unnamed, and the next start deleted it. Kept and shown as
  /// "To crop" instead: a lost write costs the shopkeeper a re-crop, not the
  /// bill. The rarer other way to get one (the app died after an upload was
  /// recorded but before its photo was removed) shows a card they discard.
  Future<List<BatchItem>> load() async {
    String? raw;
    try {
      raw = await _readRaw();
    } catch (_) {
      raw = null; // unreadable is treated as no save; its photos are adopted below
    }
    final items = <BatchItem>[];
    if (raw != null) {
      try {
        for (final entry in jsonDecode(raw) as List<dynamic>) {
          final item = BatchItem.fromJson(entry as Map<String, dynamic>);
          if (item != null) items.add(item);
        }
      } catch (_) {
        // A corrupt save is treated as no save, not a crash on every launch —
        // but its photos are kept: they may be the only copy of a bill.
        return items;
      }
    }
    /// Every holder of an unuploaded photo must be named here. Today the
    /// batch is the only one — a multi-selected photo becomes a batch
    /// item the moment it is picked, before any cropping — so this list
    /// is complete. Anything that ever holds photos outside the batch
    /// has to be added, or loading the batch adopts them as new bills.
    final referenced = {
      for (final item in items)
        for (final page in item.pages)
          if (page.photoId != null) page.photoId!,
    };
    final adopted = [
      for (final id in await PendingPhotoStore.listIds(tenantId))
        if (!referenced.contains(id))
          BatchItem(label: 'Recovered photo', pages: [
            BatchItemPage(photoId: id, memoryBytes: null, filename: '$id.jpg', corners: const [], rotationDegrees: 0),
          ])
            ..status = BatchItemStatus.needsCrop,
    ];
    if (adopted.isNotEmpty) {
      items.addAll(adopted);
      try {
        await save(items); // named now, so the next start does not adopt them again
      } catch (_) {
        // adopted again next time, which is harmless
      }
    }
    return items;
  }
}
