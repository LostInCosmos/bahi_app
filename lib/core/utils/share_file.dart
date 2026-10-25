import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The rectangle the share sheet points at: [context]'s widget, on screen.
/// iPad anchors the sheet to one, and share_plus needs it there (without it
/// the sheet can fail to open). Every share passes it, a text share included.
Rect? shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  return box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
}

/// Writes [bytes] to a temporary file called [name] and opens the system share
/// sheet for it, pointing at [context]'s widget (see [shareOrigin]).
Future<void> shareBytes(
  BuildContext context,
  List<int> bytes, {
  required String name,
  String? text,
}) async {
  final origin = shareOrigin(context);
  final dir = await sharedFilesDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: text, sharePositionOrigin: origin));
}

/// Where shared files are written: a folder of the temp directory that holds
/// nothing else, so [sweepSharedFiles] can clear it by age without touching
/// another file. A shared file stays after the sheet closes — on Android the
/// receiving app may read it only then — which is why it is swept later.
Future<Directory> sharedFilesDirectory() async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/shared');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Deletes shared files older than [olderThan] from [dir] (default: the
/// folder above) — a purchase or sales register left in temp after sharing
/// (R7, 2026-10-19 audit). Run at app start; never throws.
Future<void> sweepSharedFiles({Directory? dir, Duration olderThan = const Duration(days: 1), DateTime? now}) async {
  try {
    final folder = dir ?? await sharedFilesDirectory();
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    await for (final entity in folder.list()) {
      if (entity is File && (await entity.lastModified()).isBefore(cutoff)) await entity.delete();
    }
  } catch (_) {
    // housekeeping only
  }
}

const _savePdfChannel = MethodChannel('dastavez/save_pdf');

/// Saves a PDF through the system's own Save dialog — Downloads unless the
/// shopkeeper picks another folder; no storage permission. Returns where it
/// went, or null when the dialog was cancelled.
///
/// Android goes through `MainActivity`'s own call, which names the type
/// `application/pdf`: file_picker names none, so a second save of the same
/// name came out as `Bill-….pdf (1)`, no longer a .pdf (DAS-121). Elsewhere
/// file_picker's save sheet.
Future<String?> savePdf(Uint8List bytes, {required String name}) async {
  if (Platform.isAndroid) {
    return _savePdfChannel.invokeMethod<String>('save', {'name': name, 'bytes': bytes});
  }
  return FilePicker.platform.saveFile(
    dialogTitle: 'Save bill',
    fileName: name,
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
    bytes: bytes,
  );
}
