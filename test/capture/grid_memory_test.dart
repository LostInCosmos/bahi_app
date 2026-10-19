// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';

import 'realistic_batch.dart';

// DAS-86: measure what the capture grid holds, rather than trust the doc
// comments. Bills are built through the real models, so what is measured is
// exactly what `toJson` keeps — which is what BatchStore.save writes to
// SharedPreferences after every change, and roughly what each bill costs in
// RAM.
//
// 300 bills: the order of a real shop's batch (Testing2 held ~300).

void main() {
  test('measure: what one read bill and a 300-bill batch cost', () {
    final one = utf8.encode(jsonEncode(realisticBill(1).toJson())).length;
    final batch = utf8.encode(jsonEncode([for (var i = 0; i < 300; i++) realisticBill(i).toJson()])).length;
    final noResult = utf8.encode(jsonEncode((realisticBill(1)..result = null).toJson())).length;
    print('MEASURED one bill=${(one / 1024).toStringAsFixed(1)} KiB '
        '(${(noResult / 1024).toStringAsFixed(2)} KiB without its read), '
        '300-bill batch=${(batch / 1024 / 1024).toStringAsFixed(2)} MiB per save');
    expect(batch, greaterThan(300 * noResult), reason: 'the read is what dominates');
  });

  test('a restored bill holds no photo bytes in RAM', () {
    // Photos live on disk in PendingPhotoStore; memoryBytes is used only when
    // that write failed, and is never persisted — so nothing restored can
    // carry one, however many bills come back.
    final restored = [for (var i = 0; i < 300; i++) BatchItem.fromJson(realisticBill(i).toJson())!];
    final withBytes = restored.expand((b) => b.pages).where((p) => p.memoryBytes != null).length;
    print('MEASURED restored 300 bills: pages holding bytes in RAM=$withBytes');
    expect(withBytes, 0);
  });
}
