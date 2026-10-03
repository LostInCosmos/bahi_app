import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/api/api_exception.dart';
import 'package:gst_bill_app/features/folders/data/folder_controller.dart';
import 'package:gst_bill_app/features/folders/models/folder.dart';
import 'package:gst_bill_app/features/folders/widgets/folder_widgets.dart';

final _tree = FolderTree(const [
  Folder(id: 1, parentId: null, name: '2026'),
  Folder(id: 2, parentId: 1, name: 'Oct'),
  Folder(id: 3, parentId: 2, name: 'Week1'),
  Folder(id: 5, parentId: null, name: 'Misc'),
]);

/// What a real screen does: rebuild the bar whenever the controller changes.
Widget _owner(FolderController c, VoidCallback onNew) =>
    ListenableBuilder(listenable: c, builder: (_, __) => FolderBar(controller: c, onNewFolder: onNew));

Widget _host(Widget Function(BuildContext) body) =>
    MaterialApp(home: Scaffold(body: Builder(builder: body)));

void main() {
  group('folder picker', () {
    Future<FolderChoice?> open(WidgetTester tester, {int? currentId, bool Function(int?)? isDisabled}) async {
      FolderChoice? picked;
      var closed = false;
      await tester.pumpWidget(_host((context) => TextButton(
            onPressed: () async {
              picked = await showFolderPicker(context, tree: _tree, title: 'Move to…', currentId: currentId, isDisabled: isDisabled);
              closed = true;
            },
            child: const Text('open'),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      return picked;
    }

    testWidgets('lists Home first, then every folder', (tester) async {
      await open(tester);
      expect(find.text('Home'), findsOneWidget);
      for (final name in ['2026', 'Oct', 'Week1', 'Misc']) {
        expect(find.text(name), findsOneWidget);
      }
      // Home sits above everything else.
      expect(tester.getTopLeft(find.text('Home')).dy, lessThan(tester.getTopLeft(find.text('2026')).dy));
    });

    testWidgets('choosing Home returns a choice with no folder — not a dismissal', (tester) async {
      FolderChoice? picked;
      await tester.pumpWidget(_host((context) => TextButton(
            onPressed: () async => picked = await showFolderPicker(context, tree: _tree, title: 't', currentId: 2),
            child: const Text('open'),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.folderId, isNull);
    });

    testWidgets('a disabled destination cannot be chosen', (tester) async {
      FolderChoice? picked;
      await tester.pumpWidget(_host((context) => TextButton(
            onPressed: () async =>
                picked = await showFolderPicker(context, tree: _tree, title: 't', isDisabled: (id) => id == 5),
            child: const Text('open'),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Misc'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(picked, isNull);
      expect(find.text('Misc'), findsOneWidget, reason: 'the sheet stays open');
      await tester.tap(find.text('Oct'));
      await tester.pumpAndSettle();
      expect(picked!.folderId, 2);
    });

    testWidgets('the current location is marked', (tester) async {
      await open(tester, currentId: 2);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });

  group('name dialog', () {
    testWidgets("a server refusal shows inside the dialog and keeps what was typed", (tester) async {
      var attempts = 0;
      await tester.pumpWidget(_host((context) => TextButton(
            onPressed: () => showFolderNameDialog(
              context,
              title: 'New folder',
              submit: (name) async {
                attempts++;
                throw ApiException(409, 'a folder named "$name" already exists here');
              },
            ),
            child: const Text('open'),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'October');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(attempts, 1);
      expect(find.textContaining('already exists here'), findsOneWidget);
      expect(find.text('October'), findsOneWidget, reason: 'nothing to retype');
      expect(find.text('New folder'), findsOneWidget, reason: 'still open');
    });

    testWidgets('a blank name is not sent to the server', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(_host((context) => TextButton(
            onPressed: () => showFolderNameDialog(context, title: 'New folder', submit: (_) async => attempts++),
            child: const Text('open'),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(attempts, 0);
      expect(find.text('Give the folder a name'), findsOneWidget);
    });

    testWidgets('a good name is submitted trimmed and the dialog closes', (tester) async {
      String? sent;
      await tester.pumpWidget(_host((context) => TextButton(
            onPressed: () => showFolderNameDialog(context, title: 'New folder', submit: (n) async => sent = n),
            child: const Text('open'),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  October  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(sent, 'October');
      expect(find.text('New folder'), findsNothing);
    });
  });

  group('folder bar', () {
    testWidgets('shows the path and jumps to any part of it', (tester) async {
      final c = FolderController()
        ..tree = _tree
        ..currentId = 3;
      await tester.pumpWidget(_host((_) => FolderBar(controller: c, onNewFolder: () {})));
      for (final name in ['Home', '2026', 'Oct', 'Week1']) {
        expect(find.text(name), findsOneWidget);
      }
      await tester.tap(find.text('2026'));
      await tester.pump();
      expect(c.currentId, 1);
    });

    testWidgets('the up arrow appears inside a folder and not at home', (tester) async {
      final c = FolderController()..tree = _tree;
      await tester.pumpWidget(_host((_) => _owner(c, () {})));
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      c.open(2);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pump();
      expect(c.currentId, 1);
    });

    testWidgets('New folder is disabled at the depth cap', (tester) async {
      var taps = 0;
      final c = FolderController()
        ..tree = _tree
        ..currentId = 3; // Week1 is already 3 deep
      await tester.pumpWidget(_host((_) => _owner(c, () => taps++)));
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined), warnIfMissed: false);
      expect(taps, 0);

      c.open(null);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      expect(taps, 1);
    });
  });

  testWidgets('a folder tile says how many bills are directly inside', (tester) async {
    await tester.pumpWidget(_host((_) => Column(children: [
          FolderTile(folder: const Folder(id: 1, parentId: null, name: 'Oct', billCount: 1), onOpen: () {}, onMenu: () {}),
          FolderTile(folder: const Folder(id: 2, parentId: null, name: 'Nov', billCount: 4), onOpen: () {}, onMenu: () {}),
        ])));
    expect(find.text('1 bill'), findsOneWidget);
    expect(find.text('4 bills'), findsOneWidget);
  });
}
