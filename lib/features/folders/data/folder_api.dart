part of '../../../core/api/api_client.dart';

extension FolderApi on ApiClient {
  Future<FolderTree> listFolders() async {
    final res = await http.get(_uri('/folders'), headers: _authHeader);
    _checkOk(res);
    return FolderTree((jsonDecode(res.body) as List<dynamic>)
        .map((e) => Folder.fromJson(e as Map<String, dynamic>))
        .toList());
  }

  /// Throws ApiException(409) for a duplicate name in that place and
  /// ApiException(422) past the depth cap — surface `.message`.
  Future<Folder> createFolder(String name, {int? parentId}) async {
    final res = await http.post(
      _uri('/folders'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'parent_id': parentId}),
    );
    _checkOk(res);
    return Folder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> renameFolder(int id, String name) async {
    final res = await http.patch(
      _uri('/folders/$id'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );
    _checkOk(res);
  }

  /// [parentId] null moves it to home — sent explicitly, since the server
  /// treats an omitted parent_id as "leave it where it is".
  Future<void> moveFolder(int id, {required int? parentId}) async {
    final res = await http.patch(
      _uri('/folders/$id'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'parent_id': parentId}),
    );
    _checkOk(res);
  }

  /// Never deletes bills: they and any subfolders move up a level. Returns how
  /// many bills moved.
  Future<int> deleteFolder(int id) async {
    final res = await http.delete(_uri('/folders/$id'), headers: _authHeader);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['moved_bills']
            as int? ??
        0;
  }

  /// [folderId] null moves the bill home.
  Future<void> moveInvoice(int invoiceId, {required int? folderId}) async {
    final res = await http.patch(
      _uri('/invoices/$invoiceId/folder'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'folder_id': folderId}),
    );
    _checkOk(res);
  }
}
