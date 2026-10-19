// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/disk/bill_image_cache.dart';

// DAS-86: measure the on-disk cache rather than trust its doc comment. The
// cache's own code runs unmodified against a real temp directory; only
// path_provider is answered here, since a test has no platform to ask.

const _mib = 1024 * 1024;

int _folderBytes(Directory dir) =>
    dir.listSync().whereType<File>().fold(0, (n, f) => n + f.lengthSync());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory cacheDir;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('bill_image_cache_test');
    cacheDir = Directory('${root.path}/bill_images');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  test('measure: folder size while writing 240 MiB of 1 MiB bills', () async {
    final bill = Uint8List(_mib)..fillRange(0, _mib, 7);
    var peak = 0;
    var peakAt = 0;
    for (var i = 0; i < 240; i++) {
      await BillImageCache.write('8/bill_$i.jpg', bill);
      final size = _folderBytes(cacheDir);
      if (size > peak) {
        peak = size;
        peakAt = i;
      }
    }
    final last = _folderBytes(cacheDir);
    final kept = cacheDir.listSync().whereType<File>().length;
    print('MEASURED peak=${peak / _mib} MiB (after write #$peakAt), '
        'final=${last / _mib} MiB, files kept=$kept of 240');

    // A soft cap by design: trimming lists the whole folder, so it runs only
    // after each 20 MiB written. Between trims the folder may sit up to that
    // much over 200 MiB — never more.
    expect(peak, lessThanOrEqualTo((200 + 20) * _mib));
    expect(kept, lessThan(240), reason: 'it evicts');
  });

  test('measure: a read protects an entry from eviction (LRU by mtime)', () async {
    await BillImageCache.clear();
    final bill = Uint8List(_mib)..fillRange(0, _mib, 7);
    for (var i = 0; i < 200; i++) {
      await BillImageCache.write('8/lru_$i.jpg', bill);
    }
    // Give every entry a distinct age, oldest first, so the order is the
    // test's and not an accident of how fast the writes ran.
    final base = DateTime.now().subtract(const Duration(days: 1));
    for (var i = 0; i < 200; i++) {
      File('${cacheDir.path}/8_lru_$i.jpg').setLastModifiedSync(base.add(Duration(seconds: i)));
    }

    expect(await BillImageCache.read('8/lru_0.jpg'), isNotNull, reason: 'the oldest entry, now viewed');
    for (var i = 0; i < 25; i++) {
      await BillImageCache.write('8/new_$i.jpg', bill);   // crosses a trim point
    }

    final survivedRead = File('${cacheDir.path}/8_lru_0.jpg').existsSync();
    final oldestUnread = File('${cacheDir.path}/8_lru_1.jpg').existsSync();
    print('MEASURED lru: viewed-oldest kept=$survivedRead, next-oldest kept=$oldestUnread');
    expect(survivedRead, isTrue, reason: 'reading it made it the newest');
    expect(oldestUnread, isFalse, reason: 'the least recently used goes first');
  });
}
