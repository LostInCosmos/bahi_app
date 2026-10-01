import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// On-device store for corrected bill photos, so the same image is pulled
/// from R2 once rather than on every restore.
///
/// Why this exists: the capture screen refetches a thumbnail for every
/// restored bill on launch, and each one is the **full-resolution** corrected
/// image (up to 2000px). A dozen restored bills meant a dozen multi-megabyte
/// downloads before the grid finished drawing — slow enough to look broken.
///
/// Where it lives: the application **support** directory, not a cache or temp
/// directory. Support is app-private on both platforms (no other app can read
/// it, and on Android it is inside the app sandbox), and unlike
/// `getTemporaryDirectory()` the OS will not purge it mid-session. It is not
/// user-visible, so bill photos do not turn up in the gallery.
///
/// What it is keyed by: the server's own source-image path, e.g.
/// `6/62b7…jpg`. That path already carries the tenant id and a uuid, so one
/// shop can never address another's file, and a given path's bytes never
/// change — the server rewrites to a new uuid on re-crop. That makes the
/// entry safe to keep indefinitely and safe to serve without revalidating.
///
/// Deliberately NOT cleared on logout: logging out and back in is exactly the
/// case this is here to make fast. Nothing readable is exposed by keeping it —
/// the filenames are tenant-scoped, so the next account asks for different
/// paths and gets its own misses. [clear] exists for the account-switch case
/// if that is ever wanted.
class BillImageCache {
  BillImageCache._();

  static const _folder = 'bill_images';
  /// Trim once we are meaningfully above this. Bills are ~0.3-1.5MB each, so
  /// this holds a few hundred — far more than a shop has in flight.
  static const _maxBytes = 200 * 1024 * 1024;

  static Directory? _dir;

  static Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
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
      return bytes.isEmpty ? null : bytes;
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
      await _trim(dir);
    } catch (_) {
      // ignored on purpose — see doc comment
    }
  }

  /// Drops the least recently used entries once the folder grows past the cap.
  static Future<void> _trim(Directory dir) async {
    try {
      final files = <File>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        files.add(entity);
        total += await entity.length();
      }
      if (total <= _maxBytes) return;
      final stamped = <File, DateTime>{};
      for (final f in files) {
        stamped[f] = (await f.stat()).accessed;
      }
      files.sort((a, b) => stamped[a]!.compareTo(stamped[b]!));
      for (final f in files) {
        if (total <= _maxBytes) break;
        total -= await f.length();
        await f.delete();
      }
    } catch (_) {
      // a cache that cannot be trimmed is still a working cache
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
