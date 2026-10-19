part of '../direct_mail_gateway.dart';

mixin _DirectFolderApi on _DirectGatewayBase {
  DateTime? _folderListSyncedAt;
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

  Future<void> _refreshFolderList({bool userInitiated = false}) async {
    await _withEngine(
      (engine, _) => engine.syncFolderList(),
      userInitiated: userInitiated,
    );
    _folderListSyncedAt = _clock();
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

  // --- Folder management (filled in with the other server changes) ---------
}
