import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../models/folder.dart';

/// The folder tree plus where a screen currently is in it. Each screen that
/// browses folders (New bills, Purchases) owns one, so each remembers its own
/// position while sharing the shop's one server-side tree.
class FolderController extends ChangeNotifier {
  FolderTree tree = FolderTree.empty;

  /// The folder being looked at; null is home.
  int? currentId;

  bool loading = false;

  /// Why the last load failed, if it did. The tree keeps its last good value:
  /// being offline must not make the folders — or the bills in them — look
  /// like they vanished.
  String? loadError;

  List<Folder> get children => tree.childrenOf(currentId);
  List<Folder> get path => tree.pathTo(currentId);
  bool get atHome => currentId == null;
  bool get canCreateHere => tree.canCreateIn(currentId);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      tree = await ApiClient.instance.listFolders();
      loadError = null;
      // The folder we were in can disappear (deleted elsewhere): fall back
      // to home rather than sit inside something that no longer exists.
      if (!tree.contains(currentId)) currentId = null;
    } catch (e) {
      loadError = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void open(int? id) {
    if (id == currentId) return;
    currentId = id;
    notifyListeners();
  }

  void up() => open(tree.byId(currentId)?.parentId);

  Future<void> create(String name) async {
    await ApiClient.instance.createFolder(name, parentId: currentId);
    await load();
  }

  Future<void> rename(Folder folder, String name) async {
    await ApiClient.instance.renameFolder(folder.id, name);
    await load();
  }

  Future<void> move(Folder folder, int? newParentId) async {
    await ApiClient.instance.moveFolder(folder.id, parentId: newParentId);
    await load();
  }

  /// Bills and subfolders move up a level on the server. Returns how many
  /// saved bills moved; the caller moves any local, unsaved ones.
  Future<int> delete(Folder folder) async {
    final moved = await ApiClient.instance.deleteFolder(folder.id);
    if (currentId == folder.id) currentId = folder.parentId;
    await load();
    return moved;
  }
}
