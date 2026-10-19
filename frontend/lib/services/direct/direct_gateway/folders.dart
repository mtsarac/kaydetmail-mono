part of '../direct_mail_gateway.dart';

mixin _DirectFolderApi on _DirectGatewayBase {
  bool _folderListSyncing = false;

  static const _folderListStaleAfter = Duration(minutes: 5);

  /// The folders as stored. The first time (nothing stored) and while the
  /// server is unreachable this asks the server, so the answer is truthful
  /// about reachability; otherwise the stored list is returned at once and
  /// refreshed behind the scenes when it is old.
  Future<List<ApiMailFolder>> getFolders() async {
    final hasStored = store.folders(accountId).isNotEmpty;
    if (!hasStored || _unreachable != null) {
      try {
        await _refreshFolderList();
      } on DirectMailException catch (error) {
        // A refused command must not hide folders that are already here;
        // not reaching the server must be reported.
        if (!hasStored ||
            error.category == ApiErrorCategory.network ||
            error.category == ApiErrorCategory.timeout) {
          rethrow;
        }
      }
    } else if (_folderListSyncedAt == null ||
        _clock().difference(_folderListSyncedAt!) > _folderListStaleAfter) {
      _refreshFolderListSoon();
    }
    return _folderViews();
  }

  void _refreshFolderListSoon() {
    if (_folderListSyncing) return;
    _folderListSyncing = true;
    unawaited(() async {
      try {
        await _refreshFolderList();
        _emit(const GatewayEvent(GatewayEventKind.folders));
      } catch (_) {
        // Recorded by _run.
      } finally {
        _folderListSyncing = false;
      }
    }());
  }

  Future<int> refreshFolders() async {
    await _refreshFolderList(userInitiated: true);
    return store.folders(accountId).where((f) => f.selectable).length;
  }

  /// Folders as the app lists them: the selectable ones, each under its
  /// nearest listed ancestor.
  List<ApiMailFolder> _folderViews() {
    final all = store.folders(accountId);
    final listed = {
      for (final f in all)
        if (f.selectable) f.folderId: f,
    };
    final byId = {for (final f in all) f.folderId: f};
    String? listedParent(FolderRow folder) {
      var parent = folder.parentFolderId;
      var guard = 0;
      while (parent != null && !listed.containsKey(parent) && guard++ < 32) {
        parent = byId[parent]?.parentFolderId;
      }
      // Servers whose folders all live under `INBOX.` (cPanel, Courier)
      // put them at the top level as far as the user is concerned.
      if (parent != null && byId[parent]?.role == FolderRole.inbox) return null;
      return parent;
    }

    return [
      for (final folder in listed.values)
        ApiMailFolder(
          id: folder.folderId,
          mailAccountId: accountId,
          name: folder.name,
          fullName: folder.path,
          type: folder.role.wireName,
          unreadCount: _unreadOf(folder),
          totalCount: _totalOf(folder),
          isSyncEnabled: folder.syncEnabled,
          isAvailable: folder.available,
          delimiter: folder.delimiter.isEmpty ? null : folder.delimiter,
          parentId: listedParent(folder),
          parentIdKnown: true,
          roleOverride: folder.roleOverride?.wireName,
        ),
    ];
  }

  /// The server's own count while older mail is still to be fetched (the
  /// stored window would understate it), the stored one once all is here.
  int _unreadOf(FolderRow folder) =>
      folder.backfillComplete || folder.remoteUnseen == null
      ? store.unreadCount(accountId, folder.folderId)
      : folder.remoteUnseen!;

  int _totalOf(FolderRow folder) {
    final local = store.count(accountId, folder.folderId);
    return folder.backfillComplete
        ? local
        : max(folder.remoteExists ?? 0, local);
  }

  Future<void> syncFolderId(String folderId) async {
    _requireFolder(folderId);
    await _syncFolderNow(folderId, userInitiated: true);
  }

  // --- Folder management ---------------------------------------------------------

  ApiMailFolder _folderView(String folderId) =>
      _folderViews().firstWhere((f) => f.id == folderId);

  /// Where top-level folders of this account are created: the personal
  /// namespace prefix (`INBOX.` on many cPanel servers), else nothing.
  Future<String> _personalPrefix() => _run(
    (imap) async => (await imap.namespace())?.personalPrefix ?? '',
    userInitiated: true,
  );

  String _delimiterFor(FolderRow? parent) {
    if (parent != null && parent.delimiter.isNotEmpty) return parent.delimiter;
    for (final folder in store.folders(accountId)) {
      if (folder.delimiter.isNotEmpty) return folder.delimiter;
    }
    return '/';
  }

  Future<String> _childPath(FolderRow? parent, String name) async =>
      parent == null
      ? '${await _personalPrefix()}$name'
      : '${parent.path}${_delimiterFor(parent)}$name';

  Future<ApiMailFolder> createFolder(String name, {String? parentId}) async {
    final parent = parentId == null ? null : _requireFolder(parentId);
    final path = await _childPath(parent, name.trim());
    await _run((imap) => imap.createFolder(path), userInitiated: true);
    await _refreshFolderList(userInitiated: true);
    final created = store.folderByPath(accountId, path);
    if (created == null) {
      throw DirectMailException(DirectErrorKind.folderNotFound);
    }
    return _folderView(created.folderId);
  }

  void _requireCustom(FolderRow folder) {
    if (folder.role.isProtected || folder.roleOverride != null) {
      throw DirectMailException(DirectErrorKind.unsupportedOperation);
    }
  }

  Future<ApiMailFolder> _renameTo(
    FolderRow folder,
    String newPath,
    String name,
  ) async {
    if (newPath == folder.path) return _folderView(folder.folderId);
    await _run(
      (imap) => imap.renameFolder(folder.path, newPath),
      userInitiated: true,
    );
    store.renameFolderTree(accountId, folder.path, newPath, newName: name);
    await _refreshFolderList(userInitiated: true);
    return _folderView(folder.folderId);
  }

  Future<ApiMailFolder> renameFolder(String id, String name) async {
    final folder = _requireFolder(id);
    _requireCustom(folder);
    final parent = folder.parentFolderId == null
        ? null
        : store.folder(accountId, folder.parentFolderId!);
    final clean = name.trim();
    final newPath = parent == null
        ? (folder.delimiter.isNotEmpty && folder.path.contains(folder.delimiter)
              ? '${folder.path.substring(0, folder.path.lastIndexOf(folder.delimiter) + 1)}$clean'
              : '${await _personalPrefixOf(folder)}$clean')
        : '${parent.path}${_delimiterFor(parent)}$clean';
    return _renameTo(folder, newPath, clean);
  }

  /// The part of a top-level folder's path before its own name (the
  /// namespace prefix it lives under), kept when it is renamed.
  Future<String> _personalPrefixOf(FolderRow folder) async {
    final prefix = await _personalPrefix();
    return folder.path.startsWith(prefix) ? prefix : '';
  }

  Future<ApiMailFolder> setFolderParent(String id, String? parentId) async {
    final folder = _requireFolder(id);
    _requireCustom(folder);
    final parent = parentId == null ? null : _requireFolder(parentId);
    if (parent != null &&
        (parent.folderId == folder.folderId ||
            parent.path.startsWith('${folder.path}${_delimiterFor(parent)}'))) {
      // A folder cannot live inside itself.
      throw DirectMailException(DirectErrorKind.unsupportedOperation);
    }
    return _renameTo(
      folder,
      await _childPath(parent, folder.name),
      folder.name,
    );
  }

  /// The role is this app's own view (a server cannot be told which folder is
  /// its Sent folder), kept on the device; `null` goes back to detection.
  Future<ApiMailFolder> setFolderRole(String id, String? role) async {
    _requireFolder(id);
    final next = role == null ? null : FolderRole.fromWireName(role);
    if (next != null && !next.isAssignable) {
      throw DirectMailException(DirectErrorKind.unsupportedOperation);
    }
    store.transaction(() {
      if (next != null) {
        for (final other in store.folders(accountId)) {
          if (other.roleOverride == next && other.folderId != id) {
            store.setFolderRoleOverride(accountId, other.folderId, null);
          }
        }
      }
      store.setFolderRoleOverride(accountId, id, next);
    });
    return _folderView(id);
  }

  Future<void> deleteFolder(String id) async {
    final folder = _requireFolder(id);
    _requireCustom(folder);
    final inbox = store.folderByRole(accountId, FolderRole.inbox);
    await _run((imap) async {
      // Some servers drop the connection when the selected folder is deleted.
      if (inbox != null) await imap.select(inbox.path);
      await imap.deleteFolder(folder.path);
    }, userInitiated: true);
    store.deleteFolder(accountId, id);
  }
}
