import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/utils/share_file.dart';

/// A shared export stays in temp after the sheet closes (the receiving app
/// may read it only then); the sweep at app start removes yesterday's (R7).
void main() {
  test('sweepSharedFiles deletes files older than a day and keeps the rest', () async {
    final dir = await Directory.systemTemp.createTemp('shared_test');
    try {
      final now = DateTime(2026, 10, 19, 9);
      final old = File('${dir.path}/purchases_old.xlsx')..writeAsStringSync('x');
      await old.setLastModified(now.subtract(const Duration(days: 1, minutes: 1)));
      final fresh = File('${dir.path}/sales_today.xlsx')..writeAsStringSync('y');
      await fresh.setLastModified(now.subtract(const Duration(hours: 2)));

      await sweepSharedFiles(dir: dir, now: now);

      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a missing folder is not an error', () async {
    await sweepSharedFiles(dir: Directory('/nonexistent/shared'));
  });
}
