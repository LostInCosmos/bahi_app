import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// On-device store for corrected bill photos, so the same image is pulled
/// from R2 once rather than on every restore.
///
/// Why this exists: the capture screen refetches a thumbnail for every
/// restored bill on launch, and each one is the full corrected image. A dozen
/// restored bills meant a dozen multi-megabyte downloads before the grid
/// finished drawing — slow enough to look broken.
///
/// Where it lives, per platform:
/// - Android: the application **support** directory. App-private, never
///   purged by the OS, and kept out of backups by `allowBackup="false"`.
/// - iOS: the application **cache** directory (Library/Caches). iOS backs up
///   Application Support to iCloud by default, which would put a shop's bill
///   photos in the owner's personal iCloud backup; Caches is never backed up.
///   iOS only clears it when the device is low on storage, and everything here
///   can be fetched from R2 again, so that is an acceptable trade.
///
/// Not raw captures — those cannot be re-fetched, so they live in
/// PendingPhotoStore under Application Support instead.
///
/// What it is keyed by: the server's own source-image path, e.g.
/// `6/62b7…jpg`, plus `?v=<image_rev>` once that is nonzero (DAS-72's photo
/// rotation overwrites the same path and bumps `image_rev` for exactly this
/// reason — see ApiClient.fetchImage). A given (path, rev) pair's bytes never
/// change, so an entry is safe to keep indefinitely and to serve without
/// revalidating; a rotation is simply a different, always-missing key, and
/// the stale entry at the old key ages out through the usual LRU trim.
/// Callers only read paths belonging to the signed-in shop (see
/// ApiClient.fetchImage), since a hit never reaches the server's check.
///
/// Not cleared on logout: logging out and back in is exactly the case this
/// is here to make fast. A DIFFERENT shop signing in is what clears it — see
/// [keepOnlyShop] (DAS-90).
class BillImageCache {
  BillImageCache._();

  static const _folder = 'bill_images';

  /// Trim once we are meaningfully above this. Bills are ~0.3-1.5MB each, so
  /// this holds a few hundred — far more than a shop has in flight.
  static const _maxBytes = 200 * 1024 * 1024;

  /// Trimming lists and stats the whole folder, so it runs on the first
  /// write of a session and then only after this much more has been written,
  /// not on every write — a 50-bill batch used to mean 50 full scans.
  static const _trimEveryBytes = 20 * 1024 * 1024;
  static int? _writtenSinceTrim;

  static Directory? _dir;

  static Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final Directory base;
    if (Platform.isIOS) {
      base = await getApplicationCacheDirectory();
      await _removeLegacyIosFolder();
    } else {
      base = await getApplicationSupportDirectory();
    }
    final dir = Directory('${base.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Builds before this change kept the iOS cache in Application Support,
  /// which iCloud backs up. Removing it once means existing installs stop
  /// backing those photos up too; they are re-fetched into Caches on demand.
  static Future<void> _removeLegacyIosFolder() async {
    try {
      final old = Directory('${(await getApplicationSupportDirectory()).path}/$_folder');
      if (await old.exists()) await old.delete(recursive: true);
    } catch (_) {
      // harmless if it lingers; it is just no longer read
    }
  }

  /// `6/62b7….jpg` -> `6_62b7….jpg`. Flattens the tenant folder rather than
  /// recreating it, and keeps the path separator out of the filename.
  static String _fileName(String sourceImage) =>
      sourceImage.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Cached bytes, or null when this image has not been stored yet.
  /// Never throws: a cache that cannot be read must not stop the download.
  static Future<Uint8List?> read(String sourceImage) async {
    try {
      final file = File('${(await _directory()).path}/${_fileName(sourceImage)}');
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      // Mark it as recently used. Access time can't be trusted for this —
      // Android mounts storage without updating it on reads — so trimming
      // orders by modified time and a read bumps it here.
      try {
        await file.setLastModified(DateTime.now());
      } catch (_) {}
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Never throws: failing to cache is not a reason to fail the caller, who
  /// already has the bytes in hand.
  static Future<void> write(String sourceImage, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    try {
      final dir = await _directory();
      // Write beside the target and rename, so a kill mid-write cannot leave
      // a truncated file that later reads as a corrupt image.
      final target = File('${dir.path}/${_fileName(sourceImage)}');
      final temp = File('${target.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);

      final written = _writtenSinceTrim;
      if (written == null || written + bytes.length >= _trimEveryBytes) {
        _writtenSinceTrim = 0;
        await _trim(dir);
      } else {
        _writtenSinceTrim = written + bytes.length;
      }
    } catch (_) {
      // ignored on purpose — see doc comment
    }
  }

  /// Drops the least recently used entries once the folder grows past the cap.
  static Future<void> _trim(Directory dir) async {
    try {
      final files = <File, FileStat>{};
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        files[entity] = stat;
        total += stat.size;
      }
      if (total <= _maxBytes) return;
      final oldestFirst = files.keys.toList()
        ..sort((a, b) => files[a]!.modified.compareTo(files[b]!.modified));
      for (final f in oldestFirst) {
        if (total <= _maxBytes) break;
        total -= files[f]!.size;
        await f.delete();
      }
    } catch (_) {
      // a cache that cannot be trimmed is still a working cache
    }
  }

  /// Deletes every entry that is not [tenantId]'s. Called whenever a token is
  /// saved, so a different shop signing in leaves none of the previous shop's
  /// photos on the phone, while the same shop keeps all of its own.
  ///
  /// The shop is read off each file's name — `8/abc.jpg` is stored as
  /// `8_abc.jpg` — so nothing has to remember who was signed in before, and
  /// it holds across a restart. Never throws.
  static Future<void> keepOnlyShop(int tenantId) async {
    try {
      final dir = await _directory();
      final own = '${tenantId}_';
      await for (final entity in dir.list()) {
        if (entity is File && !entity.uri.pathSegments.last.startsWith(own)) await entity.delete();
      }
    } catch (_) {
      // a cache that cannot be pruned is still only ever read for its own shop
    }
  }

  /// Deletes [tenantId]'s entries and nobody else's — the shop's account was
  /// deleted from this device. Never throws.
  static Future<void> forgetShop(int tenantId) async {
    try {
      final dir = await _directory();
      final own = '${tenantId}_';
      await for (final entity in dir.list()) {
        if (entity is File && entity.uri.pathSegments.last.startsWith(own)) await entity.delete();
      }
    } catch (_) {
      // ignored — the next sign-in of another shop prunes it anyway
    }
  }

  static Future<void> clear() async {
    try {
      final dir = await _directory();
      if (await dir.exists()) await dir.delete(recursive: true);
      _dir = null;
    } catch (_) {
      // ignored
    }
  }
}
