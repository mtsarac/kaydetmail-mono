part of '../direct_mail_gateway.dart';

/// Changes to mail: flags, moves, copies and deletion.
///
/// Every change goes to the mail server first and the local store follows
/// only once the server accepted it, so the store never claims something the
/// server did not do. When the server cannot be reached the result is marked
/// retryable and the repository's offline queue replays it later, exactly as
/// for a backend account.
mixin _DirectActionApi on _DirectGatewayBase {
  // --- Single mail ---------------------------------------------------------------

  Future<BulkActionResult> mailAction(String id, String action) async =>
      _only(await bulkAction(action, [id]));

  Future<BulkActionResult> moveMail(String id, String folderId) async =>
      _only(await bulkAction('move', [id], folderId: folderId));

  Future<BulkActionResult> copyMail(String id, String folderId) async =>
      _only(await bulkAction('copy', [id], folderId: folderId));

  BulkActionResult _only(List<BulkActionResult> results) {
    final result = results.single;
    if (!result.success) {
      throw ApiException(
        status: 0,
        code: result.code ?? 'mail_operation_failed',
      );
    }
    return result;
  }

  // --- Many mails -------------------------------------------------------------------

  /// Applies [action] (`read`, `unread`, `star`, `unstar`, `archive`,
  /// `trash`, `spam`, `restore`, `move`, `copy`, `delete`) to [mailIds] and
  /// reports each one. Mail is handled folder by folder; once the server
  /// stops answering, the rest is reported as retryable without more
  /// attempts.
  Future<List<BulkActionResult>> bulkAction(
    String action,
    List<String> mailIds, {
    String? folderId,
  }) async {
    final ids = mailIds.toSet().toList();
    final results = <String, BulkActionResult>{};
    final byFolder = <String, List<MessageRow>>{};
    await _listPendingMoves(ids);
    for (final id in ids) {
      final row = store.message(accountId, id);
      if (row == null) {
        results[id] = BulkActionResult(
          mailId: id,
          success: false,
          code: 'mail_not_found',
        );
      } else if (row.uid == null) {
        // Moved here a moment ago and not listed by the server yet.
        results[id] = BulkActionResult(
          mailId: id,
          success: false,
          code: 'mail_reconciliation_pending',
          retryable: true,
        );
      } else {
        byFolder.putIfAbsent(row.folderId, () => []).add(row);
      }
    }

    DirectMailException? lost;
    for (final entry in byFolder.entries) {
      if (lost != null) {
        _fail(results, entry.value, lost, action);
        continue;
      }
      try {
        results.addAll(
          await _applyToFolder(
            action,
            _requireFolder(entry.key),
            entry.value,
            targetFolderId: folderId,
          ),
        );
      } on DirectMailException catch (error) {
        if (_unreachableFor(error)) lost = error;
        _fail(results, entry.value, error, action);
      }
    }
    return [for (final id in ids) results[id]!];
  }

  /// Mail this app moved a moment ago may not be listed by the server's new
  /// folder yet (a folder never opened, a server that did not say where the
  /// mail went). Acting on it, undo above all, needs its UID, so the folder
  /// is read first.
  Future<void> _listPendingMoves(List<String> ids) async {
    final folders = <String>{
      for (final id in ids)
        if (store.message(accountId, id) case final row? when row.uid == null)
          row.folderId,
    };
    for (final folderId in folders) {
      await _quietSync(folderId);
    }
  }

  /// Failures that say the server cannot be used right now rather than that
  /// it refused this request.
  static bool _unreachableFor(DirectMailException error) =>
      ConnectionPolicy.breaksConnection(error);

  void _fail(
    Map<String, BulkActionResult> results,
    List<MessageRow> rows,
    DirectMailException error,
    String action,
  ) {
    final code = switch (error.kind) {
      _ when error.category == ApiErrorCategory.network =>
        'network_unavailable',
      _ when error.category == ApiErrorCategory.timeout => 'request_timeout',
      _ when error.category == ApiErrorCategory.authentication =>
        'mail_account_needs_reauthentication',
      DirectErrorKind.rateLimited ||
      DirectErrorKind.temporaryFailure ||
      DirectErrorKind.tlsHandshakeFailed ||
      DirectErrorKind.tlsCertificateInvalid => 'mail_provider_unavailable',
      DirectErrorKind.mailboxChanged => 'mailbox_changed',
      DirectErrorKind.folderNotFound => 'mail_folder_not_found',
      DirectErrorKind.mailNotFound => 'mail_not_found',
      _ =>
        action == 'delete' ? 'mail_operation_failed' : 'mail_operation_failed',
    };
    final retryable = const {
      'network_unavailable',
      'request_timeout',
      'mail_provider_unavailable',
      'mail_account_needs_reauthentication',
    }.contains(code);
    for (final row in rows) {
      results[row.localId] = BulkActionResult(
        mailId: row.localId,
        success: false,
        code: code,
        retryable: retryable,
      );
    }
  }

  Future<Map<String, BulkActionResult>> _applyToFolder(
    String action,
    FolderRow source,
    List<MessageRow> rows, {
    String? targetFolderId,
  }) async {
    switch (action) {
      case 'read':
        return _setFlags(source, rows, add: {ImapFlags.seen});
      case 'unread':
        return _setFlags(source, rows, remove: {ImapFlags.seen});
      case 'star':
        return _setFlags(source, rows, add: {ImapFlags.flagged});
      case 'unstar':
        return _setFlags(source, rows, remove: {ImapFlags.flagged});
      case 'archive':
        return _move(source, rows, await _roleFolder(FolderRole.archive));
      case 'trash':
        return _move(source, rows, await _roleFolder(FolderRole.trash));
      case 'spam':
        return _move(source, rows, await _roleFolder(FolderRole.junk));
      case 'move':
        if (targetFolderId == null) {
          throw DirectMailException(DirectErrorKind.folderNotFound);
        }
        return _move(source, rows, _requireFolder(targetFolderId));
      case 'restore':
        return _restore(source, rows);
      case 'copy':
        if (targetFolderId == null) {
          throw DirectMailException(DirectErrorKind.folderNotFound);
        }
        return _copy(source, rows, _requireFolder(targetFolderId));
      case 'delete':
        return _expunge(source, rows);
      default:
        throw DirectMailException(DirectErrorKind.unsupportedOperation);
    }
  }

  /// Selects [folder] and refuses to go on if the server renumbered it since
  /// the last sync: the stored UIDs would then name other messages.
  Future<void> _selectChecked(ImapService imap, FolderRow folder) async {
    final state = await imap.select(folder.path);
    final known = folder.uidValidity;
    if (known != null && state.uidValidity != known) {
      _syncSoon(folder.folderId);
      throw DirectMailException(DirectErrorKind.mailboxChanged);
    }
  }

  Map<String, BulkActionResult> _succeeded(
    Iterable<MessageRow> rows, {
    Set<String> pending = const {},
  }) => {
    for (final row in rows)
      row.localId: BulkActionResult(
        mailId: row.localId,
        success: true,
        reconciliationPending: pending.contains(row.localId),
      ),
  };

  // --- Flags ---------------------------------------------------------------------------

  Future<Map<String, BulkActionResult>> _setFlags(
    FolderRow source,
    List<MessageRow> rows, {
    Set<String> add = const {},
    Set<String> remove = const {},
  }) async {
    await _run((imap) async {
      await _selectChecked(imap, source);
      await imap.storeFlags(
        source.path,
        [for (final row in rows) row.uid!],
        add: add,
        remove: remove,
      );
    }, userInitiated: true);

    bool decide(bool current, String flag) =>
        add.contains(flag) ? true : (remove.contains(flag) ? false : current);
    var unseenDelta = 0;
    store.transaction(() {
      for (final row in rows) {
        final read = decide(row.isRead, ImapFlags.seen);
        if (read != row.isRead) unseenDelta += read ? -1 : 1;
        store.updateFlags(
          accountId,
          row.localId,
          isRead: read,
          isFlagged: decide(row.isFlagged, ImapFlags.flagged),
          isAnswered: row.isAnswered,
          isDraft: row.isDraft,
          isForwarded: row.isForwarded,
          isDeleted: row.isDeleted,
          keywords: row.keywords,
        );
      }
      if (unseenDelta != 0) {
        store.adjustFolderCounts(
          accountId,
          source.folderId,
          unseenDelta: unseenDelta,
        );
      }
    });
    return _succeeded(rows);
  }

  // --- Moving --------------------------------------------------------------------------

  /// The folder playing [role], created when the account has none (the way
  /// other mail apps create "Archive" or "Trash" on first use).
  Future<FolderRow> _roleFolder(FolderRole role) async {
    final existing = store.folderByRole(accountId, role);
    if (existing != null && existing.selectable) return existing;
    // The folder may exist on the server without this device having listed
    // it yet: look before creating.
    await _refreshFolderList(userInitiated: true);
    final listed = store.folderByRole(accountId, role);
    if (listed != null && listed.selectable) return listed;
    final name = switch (role) {
      FolderRole.archive => 'Archive',
      FolderRole.trash => 'Trash',
      FolderRole.junk => 'Junk',
      FolderRole.sent => 'Sent',
      FolderRole.drafts => 'Drafts',
      _ => throw DirectMailException(DirectErrorKind.folderNotFound),
    };
    final prefix = await _run(
      (imap) async => (await imap.namespace())?.personalPrefix ?? '',
      userInitiated: true,
    );
    final path = '$prefix$name';
    await _run((imap) => imap.createFolder(path), userInitiated: true);
    await _refreshFolderList(userInitiated: true);
    final created = store.folderByPath(accountId, path);
    if (created == null) {
      throw DirectMailException(DirectErrorKind.folderNotFound);
    }
    if (created.role != role) {
      store.setFolderRoleOverride(accountId, created.folderId, role);
    }
    return store.folder(accountId, created.folderId)!;
  }

  Future<Map<String, BulkActionResult>> _move(
    FolderRow source,
    List<MessageRow> rows,
    FolderRow target,
  ) async {
    if (source.folderId == target.folderId) return _succeeded(rows);
    // Bring the target up to date first, so that the new messages land
    // directly above everything already stored there.
    if (target.lastSyncMs != null) {
      await _quietSync(target.folderId);
    }
    final result = await _run((imap) async {
      await _selectChecked(imap, source);
      return imap.move(source.path, [
        for (final row in rows) row.uid!,
      ], target.path);
    }, userInitiated: true);

    final fresh = store.folder(accountId, target.folderId)!;
    final targets = [for (final row in rows) result.targetFor(row.uid!)];
    final bound = _landsAboveStored(result, fresh, targets);
    final remember =
        target.role == FolderRole.trash || target.role == FolderRole.junk;
    final unread = rows.where((row) => !row.isRead).length;
    store.transaction(() {
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        store.moveMessage(
          accountId,
          row.localId,
          folderId: target.folderId,
          uid: bound ? targets[i] : null,
          uidValidity: bound ? result.uidValidity : null,
        );
        if (remember) {
          store.putOrigin(accountId, row.localId, source.folderId);
        } else if (source.role == FolderRole.trash ||
            source.role == FolderRole.junk) {
          store.putOrigin(accountId, row.localId, null);
        }
      }
      store.adjustFolderCounts(
        accountId,
        source.folderId,
        existsDelta: -rows.length,
        unseenDelta: -unread,
      );
      if (bound) {
        store.adjustFolderCounts(
          accountId,
          target.folderId,
          existsDelta: rows.length,
          unseenDelta: unread,
          uidNext: targets.whereType<int>().reduce(max) + 1,
        );
      }
    });

    final pending = <String>{};
    if (!bound) {
      if (target.lastSyncMs != null) await _quietSync(target.folderId);
      for (final row in rows) {
        if (store.message(accountId, row.localId)?.uid == null) {
          pending.add(row.localId);
        }
      }
    }
    return _succeeded(rows, pending: pending);
  }

  /// Whether the moved messages took the UIDs straight after the ones stored
  /// for [target]: only then can they be stored with their UIDs without
  /// leaving a gap the next sync would never look into.
  bool _landsAboveStored(
    RemoteCopyResult result,
    FolderRow target,
    List<int?> uids,
  ) {
    final next = target.uidNext;
    if (target.lastSyncMs == null ||
        next == null ||
        result.uidValidity == null ||
        target.uidValidity != result.uidValidity ||
        uids.any((uid) => uid == null)) {
      return false;
    }
    final sorted = uids.whereType<int>().toList()..sort();
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] != next + i) return false;
    }
    return true;
  }

  /// A sync whose failure does not matter to the caller (the change itself
  /// has already been made on the server).
  Future<void> _quietSync(String folderId) async {
    try {
      await _syncFolderNow(folderId, userInitiated: true);
    } on DirectMailException {
      // Reported through the reachability state; the next pass catches up.
    }
  }

  Future<Map<String, BulkActionResult>> _restore(
    FolderRow source,
    List<MessageRow> rows,
  ) async {
    final groups = <String, List<MessageRow>>{};
    for (final row in rows) {
      final origin = store.origin(accountId, row.localId);
      final folder = origin == null ? null : store.folder(accountId, origin);
      final target = folder != null && folder.available && folder.selectable
          ? folder.folderId
          : (store.folderByRole(accountId, FolderRole.inbox)?.folderId ??
                (throw DirectMailException(DirectErrorKind.folderNotFound)));
      groups.putIfAbsent(target, () => []).add(row);
    }
    final results = <String, BulkActionResult>{};
    for (final group in groups.entries) {
      results.addAll(
        await _move(source, group.value, _requireFolder(group.key)),
      );
    }
    return results;
  }

  Future<Map<String, BulkActionResult>> _copy(
    FolderRow source,
    List<MessageRow> rows,
    FolderRow target,
  ) async {
    await _run((imap) async {
      await _selectChecked(imap, source);
      await imap.copy(source.path, [
        for (final row in rows) row.uid!,
      ], target.path);
    }, userInitiated: true);
    // The copy is a new message of the target; a sync lists it.
    if (target.lastSyncMs != null) _syncSoon(target.folderId);
    return _succeeded(rows);
  }

  // --- Deleting ------------------------------------------------------------------------

  Future<Map<String, BulkActionResult>> _expunge(
    FolderRow source,
    List<MessageRow> rows,
  ) async {
    await _run((imap) async {
      await _selectChecked(imap, source);
      await imap.expunge(source.path, [for (final row in rows) row.uid!]);
    }, userInitiated: true);
    final unread = rows.where((row) => !row.isRead).length;
    store.transaction(() {
      for (final row in rows) {
        store.deleteMessage(accountId, row.localId);
      }
      store.adjustFolderCounts(
        accountId,
        source.folderId,
        existsDelta: -rows.length,
        unseenDelta: -unread,
      );
    });
    return _succeeded(rows);
  }
}
