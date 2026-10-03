import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/folders/models/folder.dart';

// Home is null throughout. These pin the tree rules the UI greys things out by
// — the server enforces the same ones and is what actually decides.

Folder f(int id, int? parent, String name, [int bills = 0]) =>
    Folder(id: id, parentId: parent, name: name, billCount: bills);

void main() {
  //  2026 ─ Oct ─ Week1
  //       └ Sep
  //  Misc
  final tree = FolderTree([
    f(1, null, '2026'),
    f(2, 1, 'Oct'),
    f(3, 2, 'Week1'),
    f(4, 1, 'sep'),
    f(5, null, 'Misc'),
  ]);

  test('children come back sorted by name, ignoring case', () {
    expect(tree.childrenOf(null).map((x) => x.name), ['2026', 'Misc']);
    expect(tree.childrenOf(1).map((x) => x.name), ['Oct', 'sep']);
    expect(tree.childrenOf(3), isEmpty);
  });

  test('path runs home to folder, and depth counts levels', () {
    expect(tree.pathTo(3).map((x) => x.name), ['2026', 'Oct', 'Week1']);
    expect(tree.pathTo(null), isEmpty);
    expect(tree.depthOf(null), 0);
    expect(tree.depthOf(1), 1);
    expect(tree.depthOf(3), 3);
  });

  test('height is the levels in a subtree, itself included', () {
    expect(tree.heightOf(3), 1);
    expect(tree.heightOf(1), 3);
    expect(tree.heightOf(5), 1);
  });

  test('a folder can be created anywhere above the depth cap, not at it', () {
    expect(tree.canCreateIn(null), isTrue);
    expect(tree.canCreateIn(2), isTrue);
    expect(tree.canCreateIn(3), isFalse, reason: 'Week1 is already 3 deep');
  });

  test('a folder cannot move into itself or its own subtree', () {
    expect(tree.canMoveFolder(1, 1), isFalse);
    expect(tree.canMoveFolder(1, 3), isFalse);
    expect(tree.isWithin(3, 1), isTrue);
    expect(tree.isWithin(5, 1), isFalse);
  });

  test('a move that would push the subtree past the cap is refused', () {
    // 2026 has 3 levels, so it can only sit at home.
    expect(tree.canMoveFolder(1, null), isTrue);
    expect(tree.canMoveFolder(1, 5), isFalse, reason: '1 + 3 > 3');
    // Misc is a single level: fine under a top-level or second-level folder.
    expect(tree.canMoveFolder(5, 2), isTrue);
    expect(tree.canMoveFolder(5, 3), isFalse, reason: '3 + 1 > 3');
  });

  test('a folder id that is not in the tree is unknown, but home always is', () {
    expect(tree.contains(null), isTrue);
    expect(tree.contains(99), isFalse);
    expect(tree.byId(99), isNull);
  });
}
