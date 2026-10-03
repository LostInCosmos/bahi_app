/// A shopkeeper's folder for saved bills. The server owns the tree; this is
/// just what it sends back.
class Folder {
  final int id;
  final int? parentId;
  final String name;

  /// Bills directly inside (not in subfolders) — what a delete confirmation
  /// says will move.
  final int billCount;

  const Folder(
      {required this.id,
      required this.parentId,
      required this.name,
      this.billCount = 0});

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        id: json['id'] as int,
        parentId: json['parent_id'] as int?,
        name: json['name'] as String,
        billCount: json['bill_count'] as int? ?? 0,
      );
}

/// The whole folder tree, held flat. `null` is home throughout: a folder whose
/// parent is null is at the top level, and a bill whose folder is null is
/// not in any folder.
class FolderTree {
  /// Same cap the server enforces (services/folder/handlers.py MAX_DEPTH); kept
  /// here only so the UI can grey out a move or a "New folder" that the
  /// server would refuse. The server remains the one that decides.
  static const maxDepth = 3;

  final List<Folder> folders;
  final Map<int, Folder> _byId;

  FolderTree(this.folders) : _byId = {for (final f in folders) f.id: f};

  static final empty = FolderTree(const []);

  Folder? byId(int? id) => id == null ? null : _byId[id];
  bool contains(int? id) => id == null || _byId.containsKey(id);

  List<Folder> childrenOf(int? parentId) {
    final out = folders.where((f) => f.parentId == parentId).toList();
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Home-to-here, inclusive of [id] itself; empty for home.
  List<Folder> pathTo(int? id) {
    final path = <Folder>[];
    var node = byId(id);
    while (node != null) {
      path.add(node);
      node = byId(node.parentId);
    }
    return path.reversed.toList();
  }

  /// 0 for home, 1 for a top-level folder.
  int depthOf(int? id) => pathTo(id).length;

  /// Levels in the subtree rooted at [id], itself included.
  int heightOf(int id) {
    final kids = childrenOf(id);
    return 1 +
        (kids.isEmpty
            ? 0
            : kids.map((k) => heightOf(k.id)).reduce((a, b) => a > b ? a : b));
  }

  /// True when [id] is [ancestorId] or sits anywhere beneath it.
  bool isWithin(int? id, int ancestorId) =>
      pathTo(id).any((f) => f.id == ancestorId);

  bool canCreateIn(int? parentId) => depthOf(parentId) < maxDepth;

  /// Whether folder [id] may be moved under [newParentId]: not into itself or
  /// its own subtree, and not so deep that its subtree overflows the cap.
  bool canMoveFolder(int id, int? newParentId) {
    if (newParentId != null && isWithin(newParentId, id)) return false;
    return depthOf(newParentId) + heightOf(id) <= maxDepth;
  }
}
