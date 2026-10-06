import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../../core/utils/pending_photo_store.dart';
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
class BatchStore {
  final int tenantId;

  BatchStore._(this.tenantId);

  /// Null when nobody is signed in.
  static BatchStore? forCurrentUser() {
    final tid = ApiClient.instance.tenantId;
    return tid == null ? null : BatchStore._(tid);
  }

  String get _key => 'bahi_batch_$tenantId';

  Future<void> save(List<BatchItem> items) async {
    final serializable = items.where((i) => i.isPersistable).map((i) => i.toJson()).toList();
    final prefs = await SharedPreferences.getInstance();
    if (serializable.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode(serializable));
    }
  }

  /// The saved batch, in order. Also deletes this shop's pending photo files
  /// that nothing refers to any more — left behind if the app died between an
  /// upload succeeding and its file being removed.
  Future<List<BatchItem>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
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
    /// has to be added, or loading the batch silently deletes them.
    final referenced = {
      for (final item in items)
        for (final page in item.pages)
          if (page.photoId != null) page.photoId!,
    };
    await PendingPhotoStore.deleteOrphans(tenantId, referenced);
    return items;
  }
}
