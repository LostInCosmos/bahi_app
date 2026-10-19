import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Raw bill photos that have been captured and cropped but not yet uploaded.
///
/// A photo is written here the moment its crop is confirmed, and the upload
/// reads it back from here — so a logout, a kill, a crash or an app update
/// partway through a large batch costs nothing: the capture screen finds the
/// file on its next start and uploads it then. The file is deleted only once
/// the server has accepted it.
///
/// Lives in the application support directory, never cache/temp: unlike the
/// corrected images in [BillImageCache], these cannot be fetched again from
/// anywhere if the OS purges them. App-private on both platforms, and Android
/// backup is off (see AndroidManifest). Files are named `<tenantId>_<id>.jpg`
/// so one shop's cleanup never touches another shop's pending photos on a
/// shared device.
class PendingPhotoStore {
  PendingPhotoStore._();

  static const _folder = 'pending_photos';
  static final _random = Random();
  static Directory? _dir;

  static Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  static Future<File> _file(String id) async => File('${(await _directory()).path}/$id.jpg');

  /// Returns the new photo's id, or null if it could not be written — the
  /// caller then keeps the bytes in memory only, as before this existed.
  static Future<String?> save(int tenantId, Uint8List bytes) async {
    try {
      final id = '${tenantId}_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}';
      final target = await _file(id);
      // Write beside the target and rename, so a kill mid-write cannot leave
      // a truncated photo that later uploads as a corrupt image.
      final temp = File('${target.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      return id;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> read(String id) async {
    try {
      final file = await _file(id);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(String id) async {
    try {
      final file = await _file(id);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // a leftover file is swept by deleteOrphans on the next start
    }
  }

  /// Deletes this tenant's photos that no persisted batch item refers to —
  /// left behind if the app died between an upload succeeding and its file
  /// being deleted. Other tenants' files are never touched.
  static Future<void> deleteOrphans(int tenantId, Set<String> keep) async {
    try {
      final prefix = '${tenantId}_';
      await for (final entity in (await _directory()).list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(prefix)) continue;
        final id = name.endsWith('.jpg') ? name.substring(0, name.length - 4) : name;
        if (!keep.contains(id)) await entity.delete();
      }
    } catch (_) {
      // ignored — this is housekeeping, not correctness
    }
  }
}
