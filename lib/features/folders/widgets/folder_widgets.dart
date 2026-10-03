import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_exception.dart';
import '../data/folder_controller.dart';
import '../models/folder.dart';

/// Breadcrumb for where you are (Home › 2026 › October), tap any part to jump
/// there, plus the New folder action. Shared by New bills and Purchases.
class FolderBar extends StatelessWidget {
  final FolderController controller;
  final VoidCallback onNewFolder;
  const FolderBar(
      {super.key, required this.controller, required this.onNewFolder});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = controller.path;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.s, Spacing.xs, Spacing.xs, 0),
      child: Row(children: [
        if (!controller.atHome)
          IconButton(
            tooltip: 'Up one level',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: controller.up,
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse:
                true, // keep the current folder in view when the path is long
            child: Row(children: [
              _Crumb(
                  label: 'Home',
                  icon: Icons.home_outlined,
                  current: controller.atHome,
                  onTap: () => controller.open(null)),
              for (final f in path) ...[
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: colors.outline),
                _Crumb(
                    label: f.name,
                    current: f.id == controller.currentId,
                    onTap: () => controller.open(f.id)),
              ],
            ]),
          ),
        ),
        IconButton(
          tooltip: controller.canCreateHere
              ? 'New folder'
              : 'Folders can only go ${FolderTree.maxDepth} levels deep',
          icon: const Icon(Icons.create_new_folder_outlined),
          onPressed: controller.canCreateHere ? onNewFolder : null,
        ),
      ]),
    );
  }
}

class _Crumb extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool current;
  final VoidCallback onTap;
  const _Crumb(
      {required this.label,
      this.icon,
      required this.current,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: current ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xs, vertical: Spacing.s),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon,
                size: 18, color: current ? colors.onSurface : colors.primary),
            const SizedBox(width: 2)
          ],
          Text(
            label,
            style: TextStyle(
              fontWeight: current ? FontWeight.w700 : FontWeight.w500,
              color: current ? colors.onSurface : colors.primary,
            ),
          ),
        ]),
      ),
    );
  }
}

/// A folder as a compact tile — name and how many bills are directly in it.
/// Long-press (or the menu) for rename / move / delete.
class FolderTile extends StatelessWidget {
  final Folder folder;
  final VoidCallback onOpen;
  final VoidCallback onMenu;
  const FolderTile(
      {super.key,
      required this.folder,
      required this.onOpen,
      required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.card / 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card / 2),
        onTap: () {
          HapticFeedback.selectionClick();
          onOpen();
        },
        onLongPress: () {
          HapticFeedback.mediumImpact();
          onMenu();
        },
        child: Padding(
          padding: const EdgeInsets.only(left: Spacing.m),
          child: Row(children: [
            Icon(Icons.folder_rounded, color: colors.primary),
            const SizedBox(width: Spacing.s),
            Expanded(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                        '${folder.billCount} ${folder.billCount == 1 ? 'bill' : 'bills'}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant)),
                  ]),
            ),
            IconButton(
              tooltip: 'Folder options',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onPressed: onMenu,
            ),
          ]),
        ),
      ),
    );
  }
}

/// A grid of [FolderTile]s, two across, sized to the compact tile rather than
/// the bill cards' aspect ratio.
SliverPadding folderTileGrid({
  required List<Folder> folders,
  required void Function(Folder) onOpen,
  required void Function(Folder) onMenu,
}) {
  return SliverPadding(
    padding: const EdgeInsets.fromLTRB(Spacing.m, Spacing.s, Spacing.m, 0),
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: Spacing.s,
        crossAxisSpacing: Spacing.s,
        mainAxisExtent: 56,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => FolderTile(
            folder: folders[i],
            onOpen: () => onOpen(folders[i]),
            onMenu: () => onMenu(folders[i])),
        childCount: folders.length,
      ),
    ),
  );
}

/// The same tiles for a screen built on a plain ListView rather than slivers.
Widget folderTileGridBox({
  required List<Folder> folders,
  required void Function(Folder) onOpen,
  required void Function(Folder) onMenu,
}) {
  return GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: Spacing.s,
      crossAxisSpacing: Spacing.s,
      mainAxisExtent: 56,
    ),
    itemCount: folders.length,
    itemBuilder: (context, i) => FolderTile(
        folder: folders[i],
        onOpen: () => onOpen(folders[i]),
        onMenu: () => onMenu(folders[i])),
  );
}

// ------------------------------------------------------------------ dialogs

/// Asks for a folder name and hands it to [submit]. A refusal from the server
/// (duplicate, too deep) comes back as [submit] throwing, and is shown inside
/// the dialog so the shopkeeper can fix it without retyping. Returns whether a
/// name was accepted.
Future<bool> showFolderNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  required Future<void> Function(String name) submit,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _FolderNameDialog(title: title, initial: initial, submit: submit),
  );
  return done == true;
}

/// Owns its controller: disposing one from outside the dialog while the route
/// is still animating closed throws, because the TextField is still on screen.
class _FolderNameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final Future<void> Function(String name) submit;
  const _FolderNameDialog(
      {required this.title, required this.initial, required this.submit});

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the folder a name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(name);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 100,
        textCapitalization: TextCapitalization.sentences,
        decoration:
            InputDecoration(labelText: 'Folder name', errorText: _error),
        onSubmitted: (_) => _busy ? null : _go(),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _go, child: const Text('Save')),
      ],
    );
  }
}

/// The New folder action: asks for a name and creates it where the controller
/// currently is. Both folder screens use it.
Future<bool> showNewFolderDialog(BuildContext context, FolderController controller) =>
    showFolderNameDialog(context, title: 'New folder', submit: controller.create);

/// What the picker returns — a wrapper so "Home" (null) can be told apart from
/// "dismissed" (a null result).
class FolderChoice {
  final int? folderId;
  const FolderChoice(this.folderId);
}

/// Pick a destination: Home first, then every folder indented by depth.
/// [disabled] greys entries that can't be chosen (a folder's own subtree, or
/// somewhere that would push it past the depth cap); [currentId] is marked.
Future<FolderChoice?> showFolderPicker(
  BuildContext context, {
  required FolderTree tree,
  required String title,
  int? currentId,
  bool Function(int? folderId)? isDisabled,
}) {
  final rows = <_PickerRow>[_PickerRow(null, 'Home', 0)];
  void walk(int? parent, int depth) {
    for (final f in tree.childrenOf(parent)) {
      rows.add(_PickerRow(f.id, f.name, depth));
      walk(f.id, depth + 1);
    }
  }

  walk(null, 1);
  return showModalBottomSheet<FolderChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(Spacing.l, 0, Spacing.l, Spacing.s),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium)),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final r in rows)
                ListTile(
                  enabled: !(isDisabled?.call(r.id) ?? false),
                  contentPadding: EdgeInsets.only(
                      left: Spacing.l + r.depth * Spacing.l, right: Spacing.l),
                  leading: Icon(r.id == null
                      ? Icons.home_outlined
                      : Icons.folder_outlined),
                  title: Text(r.name),
                  trailing: r.id == currentId
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(context, FolderChoice(r.id)),
                ),
            ]),
          ),
        ]),
      ),
    ),
  );
}

class _PickerRow {
  final int? id;
  final String name;
  final int depth;
  _PickerRow(this.id, this.name, this.depth);
}

/// Rename / move / delete for one folder. [onDeleted] gets the folder and how
/// many saved bills the server moved, so a screen holding unsaved bills can
/// move its own copies up a level too.
Future<void> showFolderActions(
  BuildContext context,
  FolderController controller,
  Folder folder, {
  void Function(Folder folder, int movedBills)? onDeleted,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            leading: const Icon(Icons.folder_rounded),
            title: Text(folder.name,
                style: const TextStyle(fontWeight: FontWeight.w700))),
        ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename'),
            onTap: () => Navigator.pop(context, 'rename')),
        ListTile(
            leading: const Icon(Icons.drive_file_move_outlined),
            title: const Text('Move to…'),
            onTap: () => Navigator.pop(context, 'move')),
        ListTile(
          leading: Icon(Icons.delete_outline,
              color: Theme.of(context).colorScheme.error),
          title: Text('Delete folder',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () => Navigator.pop(context, 'delete'),
        ),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;

  void fail(Object e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : '$e')));
  }

  switch (action) {
    case 'rename':
      await showFolderNameDialog(context,
          title: 'Rename folder',
          initial: folder.name,
          submit: (n) => controller.rename(folder, n));
    case 'move':
      final choice = await showFolderPicker(
        context,
        tree: controller.tree,
        title: 'Move "${folder.name}" to…',
        currentId: folder.parentId,
        isDisabled: (id) => !controller.tree.canMoveFolder(folder.id, id),
      );
      if (choice == null || choice.folderId == folder.parentId) return;
      try {
        await controller.move(folder, choice.folderId);
      } catch (e) {
        fail(e);
      }
    case 'delete':
      final parentName = controller.tree.byId(folder.parentId)?.name ?? 'Home';
      final subfolders = controller.tree.childrenOf(folder.id).length;
      final contents = <String>[
        if (folder.billCount > 0)
          '${folder.billCount} ${folder.billCount == 1 ? 'bill' : 'bills'}',
        if (subfolders > 0)
          '$subfolders ${subfolders == 1 ? 'folder' : 'folders'}',
      ];
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete "${folder.name}"?'),
          content: Text(contents.isEmpty
              ? 'This folder is empty.'
              : 'Its ${contents.join(' and ')} will move to $parentName. No bills are deleted.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete folder')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        final moved = await controller.delete(folder);
        onDeleted?.call(folder, moved);
      } catch (e) {
        fail(e);
      }
  }
}
