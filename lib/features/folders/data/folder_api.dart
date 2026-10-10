part of '../../../core/api/api_client.dart';

extension FolderApi on ApiClient {
  Future<FolderTree> listFolders() async => FolderTree(
      ApiClient._list(await _get('/folders')).map((e) => Folder.fromJson(e as Map<String, dynamic>)).toList());

  /// Throws ApiException(409) for a duplicate name in that place and
  /// ApiException(422) past the depth cap — surface `.message`.
  Future<Folder> createFolder(String name, {int? parentId}) async =>
      Folder.fromJson(ApiClient._object(await _postJson('/folders', {'name': name, 'parent_id': parentId})));

  Future<void> renameFolder(int id, String name) => _patchJson('/folders/$id', {'name': name});

  /// [parentId] null moves it to home — sent explicitly, since the server
  /// treats an omitted parent_id as "leave it where it is".
  Future<void> moveFolder(int id, {required int? parentId}) => _patchJson('/folders/$id', {'parent_id': parentId});

  /// Never deletes bills: they and any subfolders move up a level. Returns how
  /// many bills moved.
  Future<int> deleteFolder(int id) async =>
      ApiClient._object(await _delete('/folders/$id'))['moved_bills'] as int? ?? 0;

  /// [folderId] null moves the bill home.
  Future<void> moveInvoice(int invoiceId, {required int? folderId}) =>
      _patchJson('/invoices/$invoiceId/folder', {'folder_id': folderId});
}
