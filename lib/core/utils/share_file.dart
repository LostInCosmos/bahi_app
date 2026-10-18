import 'dart:io';

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
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: text, sharePositionOrigin: origin));
}
