part of '../direct_mail_gateway.dart';

/// Searching the mailbox: first on this device (instant, offline, Turkish
/// letters folded), then, when the user asks, on the mail server itself.
mixin _DirectSearchApi on _DirectGatewayBase, _DirectMailApi, _DirectActionApi {
  /// Most messages one server search brings in (with their text, so the
  /// device can search them again). The screen asks again while some remain.
  static const _importBudget = 40;

  Future<MailListPage> search({
    required String query,
    required MailFolder Function(String folderId) resolveFolder,
    String? folderId,
    String? conversationId,
    String? from,
    String? to,
    DateTime? fromDate,
    DateTime? toDate,
    bool? isRead,
    bool? flagged,
    bool? hasAttachment,
    String? labelId,
    int page = 1,
    int pageSize = 20,
  }) async {
    // Searching everywhere leaves out Trash and Spam, like other mail apps;
    // opening one of them and searching there finds what is in it.
    final skipped = folderId != null
        ? const <String>[]
        : [
            for (final f in store.folders(accountId))
              if (f.role == FolderRole.trash || f.role == FolderRole.junk)
                f.folderId,
          ];
    final found = store.searchMessages(
      accountId,
      query: query,
      inFolders: folderId == null ? null : [folderId],
      exceptFolders: skipped,
      from: from,
      to: to,
      since: fromDate,
      before: toDate,
      isRead: isRead,
      flagged: flagged,
      hasAttachment: hasAttachment,
      labelId: labelId,
      threadId: conversationId,
      offset: (page - 1) * pageSize,
      limit: pageSize,
    );
    return MailListPage(
      items: [
        for (final row in found.rows)
          DirectEmailMapper.listItem(
            row,
            resolveFolder: resolveFolder,
            accountId: accountId,
          ),
      ],
      page: page,
      pageSize: pageSize,
      total: found.total,
    );
  }

  /// Asks the mail server and keeps what it finds, so the local search sees
  /// it from then on. At most [_importBudget] messages are brought in per
  /// call; [RemoteSearchResult.remaining] says how many more there are.
  Future<RemoteSearchResult> searchRemote({
    required String query,
    String? folderId,
    String? conversationId,
    String? from,
    String? to,
    DateTime? fromDate,
    DateTime? toDate,
    bool? isRead,
    bool? flagged,
    bool? hasAttachment,
    String? labelId,
  }) async {
    final folders = folderId != null
        ? [_requireFolder(folderId)]
        : [
            for (final f in store.folders(accountId))
              if (f.selectable &&
                  f.role != FolderRole.trash &&
                  f.role != FolderRole.junk)
                f,
          ];
    final wanted = RemoteSearchQuery(
      text: query,
      from: from,
      to: to,
      since: fromDate,
      before: toDate,
      unseen: isRead == null ? null : !isRead,
      flagged: flagged,
    );
    var matched = 0;
    var imported = 0;
    var remaining = 0;
    for (final folder in folders) {
      final uids = await _run((imap) async {
        await _selectChecked(imap, folder);
        return imap.search(folder.path, wanted);
      }, userInitiated: true);
      matched += uids.length;
      final stored = store.uids(accountId, folder.folderId).toSet();
      final fresh = [
        for (final uid in uids.reversed)
          if (!stored.contains(uid)) uid,
      ];
      final room = _importBudget - imported;
      final take = fresh.take(room < 0 ? 0 : room).toList();
      if (take.isNotEmpty) {
        final added = await _withEngine(
          (engine, _) =>
              engine.importMessages(folder.folderId, take, withBodies: true),
          userInitiated: true,
        );
        imported += added.length;
      }
      remaining += fresh.length - take.length;
    }
    return RemoteSearchResult(
      matched: matched,
      imported: imported,
      remaining: remaining,
      complete: remaining == 0,
    );
  }
}
