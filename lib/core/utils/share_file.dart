import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Writes [bytes] to a temporary file called [name] and opens the system share
/// sheet for it. [context] is the widget the sheet should point at: iPad
/// anchors the sheet to a rectangle, and share_plus needs one there (without
/// it the sheet can fail to open). The file is removed once the sheet closes.
Future<void> shareBytes(
  BuildContext context,
  List<int> bytes, {
  required String name,
  String? text,
}) async {
  final box = context.findRenderObject();
  final origin = box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: text, sharePositionOrigin: origin));
}
