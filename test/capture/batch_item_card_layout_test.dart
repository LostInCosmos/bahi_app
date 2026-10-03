import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/capture/widgets/batch_item_card.dart';
import 'package:gst_bill_app/features/folders/models/folder.dart';
import 'package:gst_bill_app/features/folders/widgets/folder_widgets.dart';

// The grid went from two across to three so more bills fit, and each card now
// carries a Move button next to delete, reprocess and the status badge. A
// RenderFlex overflow or overlapping hit area would throw here, at the width
// of a small phone.

BatchItem _item(BatchItemStatus status, {String label = 'Photo 1'}) =>
    BatchItem(label: label, pages: [])
      ..sourceImages = ['7/a.jpg']
      ..status = status;

Widget _grid(List<BatchItem> items, {void Function(BatchItem)? onMove}) => MaterialApp(
      home: Scaffold(
        body: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.75,
          ),
          itemCount: items.length,
          itemBuilder: (_, i) => BatchItemCard(
            item: items[i],
            onTap: () {},
            onDelete: () {},
            onReprocess: () {},
            onMove: onMove == null ? null : () => onMove(items[i]),
          ),
        ),
      ),
    );

void main() {
  testWidgets('every card state fits three across on a 320dp-wide phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_grid([
      for (final s in BatchItemStatus.values) _item(s, label: 'A fairly long bill label ${s.name}'),
    ], onMove: (_) {}));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.drive_file_move_outlined), findsNWidgets(BatchItemStatus.values.length));
  });

  testWidgets('tapping Move reports that bill, and the card itself is not opened', (tester) async {
    BatchItem? moved;
    var opened = 0;
    final item = _item(BatchItemStatus.pendingConfirm);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 110,
          height: 150,
          child: BatchItemCard(item: item, onTap: () => opened++, onDelete: null, onReprocess: null, onMove: () => moved = item),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.drive_file_move_outlined));
    expect(moved, same(item));
    expect(opened, 0);
  });

  testWidgets('no Move button when the card has no move action', (tester) async {
    await tester.pumpWidget(_grid([_item(BatchItemStatus.processing)]));
    await tester.pump();
    expect(find.byIcon(Icons.drive_file_move_outlined), findsNothing);
  });

  testWidgets('long folder names are clipped, not overflowed, in the two-across tile grid', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: folderTileGridBox(
          folders: const [
            Folder(id: 1, parentId: null, name: 'A very long supplier and month folder name that cannot possibly fit', billCount: 120),
            Folder(id: 2, parentId: null, name: 'Oct', billCount: 1),
          ],
          onOpen: (_) {},
          onMenu: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('120 bills'), findsOneWidget);
  });
}
