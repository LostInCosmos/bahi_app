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

  testWidgets('a bill being read or flagged says "Under processing" and shows no spinner (DAS-71)', (tester) async {
    for (final status in [BatchItemStatus.processing, BatchItemStatus.needsReview]) {
      await tester.pumpWidget(_grid([_item(status)]));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '$status');
    }
    // Being read: the words sit over the photo; flagged: the same grey badge as
    // a bill being read, not the amber exclamation mark of one waiting for a person.
    await tester.pumpWidget(_grid([_item(BatchItemStatus.processing)]));
    await tester.pumpAndSettle();
    expect(find.text('Under processing'), findsOneWidget);
    await tester.pumpWidget(_grid([_item(BatchItemStatus.needsReview)]));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.priority_high_rounded), findsNothing);
    expect(find.byIcon(Icons.hourglass_empty_rounded), findsOneWidget);
  });

  group('asking again while our team might still have the bill (DAS-76, extended to pendingConfirm by DAS-79)', () {
    testWidgets('a needsReview card asks once when built, and not again on a later rebuild', (tester) async {
      var asked = 0;
      final item = _item(BatchItemStatus.needsReview);
      Widget card() => MaterialApp(
            home: Scaffold(
              body: BatchItemCard(
                item: item,
                onTap: () {},
                onDelete: null,
                onReprocess: null,
                onRecheckNeedsReview: (_) => asked++,
              ),
            ),
          );

      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(asked, 1);

      // Rebuilt again (e.g. a sibling card's state changed) — still the
      // same needsReview episode, so it must not ask a second time.
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(asked, 1);
    });

    testWidgets('a pendingConfirm card asks once too — it may be clean but still unverified (DAS-79)',
        (tester) async {
      var asked = 0;
      final item = _item(BatchItemStatus.pendingConfirm);
      Widget card() => MaterialApp(
            home: Scaffold(
              body: BatchItemCard(
                item: item,
                onTap: () {},
                onDelete: null,
                onReprocess: null,
                onRecheckNeedsReview: (_) => asked++,
              ),
            ),
          );

      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(asked, 1);

      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(asked, 1, reason: 'same episode, not asked twice');
    });

    testWidgets('a card that is neither never asks', (tester) async {
      var asked = 0;
      for (final status in BatchItemStatus.values.where(
          (s) => s != BatchItemStatus.needsReview && s != BatchItemStatus.pendingConfirm)) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: BatchItemCard(
              item: _item(status),
              onTap: () {},
              onDelete: null,
              onReprocess: null,
              onRecheckNeedsReview: (_) => asked++,
            ),
          ),
        ));
        await tester.pumpAndSettle();
      }
      expect(asked, 0);
    });

    testWidgets('a bill flagged again after being cleared asks again, once', (tester) async {
      var asked = 0;
      final item = _item(BatchItemStatus.needsReview);
      Widget card() => MaterialApp(
            home: Scaffold(
              body: BatchItemCard(
                item: item,
                onTap: () {},
                onDelete: null,
                onReprocess: null,
                onRecheckNeedsReview: (_) => asked++,
              ),
            ),
          );

      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(asked, 1);

      // Cleared, then flagged again — a fresh episode, so it is asked about
      // once more, same as if it had never been checked before. Production
      // code resets the flag at the exact point it (re-)assigns needsReview
      // (see capture_screen.dart); simulated here the same way.
      item.status = BatchItemStatus.pendingConfirm;
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      item
        ..status = BatchItemStatus.needsReview
        ..recheckedThisReview = false;
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(asked, 2);
    });
  });
}
