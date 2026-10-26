import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/disk/pending_photo_store.dart';
import 'package:gst_bill_app/features/capture/data/batch_store.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';

// DAS-135, items 5 and 7. A photo is written to disk before the batch that
// names it, and shared_preferences does not promise the batch reached disk,
// so a kill in between left the only copy of a bill unnamed — and the next
// start deleted it as an orphan. Now it comes back as a bill to crop. And on
// iOS the batch is a file in a folder kept out of iCloud, not a preference
// in the backed-up UserDefaults plist.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('batch_store_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BatchStore.debugUseFile = null;
    BatchStore.debugResetDirectory();
    // Emptied, not deleted: PendingPhotoStore remembers its folder.
    final photos = Directory('${dir.path}/pending_photos');
    if (photos.existsSync()) {
      for (final f in photos.listSync()) {
        f.deleteSync();
      }
    }
    final batches = Directory('${dir.path}/capture_batch');
    if (batches.existsSync()) batches.deleteSync(recursive: true);
  });

  Future<String> photo(int tenant) async => (await PendingPhotoStore.save(tenant, Uint8List.fromList([1, 2, 3])))!;

  test('a photo on the device that the batch does not name comes back as a bill to crop, not deleted', () async {
    final unnamed = await photo(8);
    final store = BatchStore.forTenant(8);

    final items = await store.load();

    expect(items, hasLength(1));
    expect(items.single.status, BatchItemStatus.needsCrop);
    expect(items.single.pages.single.photoId, unnamed);
    expect(await PendingPhotoStore.read(unnamed), isNotNull, reason: 'the only copy of the bill is kept');

    final again = await store.load();
    expect(again, hasLength(1), reason: 'named now, so it is not adopted twice');
  });

  test('a photo the batch names is not adopted again, and another shop\'s photo is left alone', () async {
    final named = await photo(8);
    final other = await photo(9);
    final item = BatchItem(label: 'Photo 1', pages: [
      BatchItemPage(photoId: named, memoryBytes: null, filename: 'b.jpg', corners: const [], rotationDegrees: 0),
    ])
      ..status = BatchItemStatus.preparing;
    await BatchStore.forTenant(8).save([item]);

    final items = await BatchStore.forTenant(8).load();

    expect(items, hasLength(1));
    expect(items.single.pages.single.photoId, named);
    expect(await PendingPhotoStore.read(other), isNotNull);
  });

  test('on iOS the batch is a file, and one an older build left in preferences is moved there', () async {
    BatchStore.debugUseFile = true;
    final legacy = [
      {'label': 'Photo 1', 'sourceImages': ['8/1.jpg'], 'pages': [], 'status': 'ready'},
    ];
    SharedPreferences.setMockInitialValues({'bahi_batch_8': jsonEncode(legacy)});

    final items = await BatchStore.forTenant(8).load();

    expect(items.single.sourceImages, ['8/1.jpg']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bahi_batch_8'), isNull, reason: 'no longer in the backed-up UserDefaults');
    final file = File('${dir.path}/capture_batch/batch_8.json');
    expect(file.existsSync(), isTrue);

    await BatchStore.forTenant(8).save(const []);
    expect(file.existsSync(), isFalse, reason: 'an empty batch leaves nothing behind');
  });
}
