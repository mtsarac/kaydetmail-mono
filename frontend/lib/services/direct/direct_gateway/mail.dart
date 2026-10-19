part of '../direct_mail_gateway.dart';

mixin _DirectMailApi on _DirectGatewayBase {
  // --- Lists -----------------------------------------------------------------

  /// A page of [folderId] from the store. The first time a folder is opened it
  /// is synced first (the user waits for something to show); afterwards the
  /// stored mail is returned at once and an old folder is brought up to date
  /// in the background ([events] reports what changed). Scrolling past the
  /// stored window fetches older mail from the server on demand.
  Future<MailListPage> getMails({
    required String folderId,
    required MailFolder Function(String folderId) resolveFolder,
    int page = 1,
    int pageSize = 20,
    bool? isRead,
    bool? hasAttachments,
    String? search,
  }) async {
    var folder = _requireFolder(folderId);
    final text = (search ?? '').trim();
    final filtered =
        isRead != null || hasAttachments != null || text.isNotEmpty;

    int localCount() => store.count(
      accountId,
      folderId,
      isRead: isRead,
      hasAttachments: hasAttachments,
      text: text,
    );

    if (folder.selectable) {
      if (folder.lastSyncMs == null) {
        try {
          await _syncFolderNow(folderId, userInitiated: true);
        } on DirectMailException {
          if (store.count(accountId, folderId) == 0) rethrow;
        }
      } else if (_isStale(folder)) {
        _syncSoon(folderId);
      }
    }

    final offset = (page - 1) * pageSize;
    var local = localCount();
    Object? fetchError;
    var rounds = 0;
    folder = _requireFolder(folderId);
    while (folder.selectable &&
        !folder.backfillComplete &&
        local < offset + pageSize &&
        rounds < (filtered ? 3 : 1)) {
      try {
        final stored = await _withEngine(
          (engine, _) => engine.backfill(
            folderId,
            count: max(syncOptions.initialWindow, pageSize),
          ),
          userInitiated: true,
        );
        if (stored == 0) break;
      } on DirectMailException catch (error) {
        fetchError = error;
        break;
      }
      rounds++;
      local = localCount();
      folder = _requireFolder(folderId);
    }

    final rows = store.page(
      accountId,
      folderId,
      offset: offset,
      limit: pageSize,
      isRead: isRead,
      hasAttachments: hasAttachments,
      text: text,
    );
    // An empty page that is only empty because older mail could not be
    // fetched is an error, not the end of the folder (the list would stop
    // asking for more).
    if (rows.isEmpty && fetchError != null) throw fetchError;

    final total = filtered || folder.backfillComplete
        ? local
        : max(folder.remoteExists ?? 0, local);
    return MailListPage(
      items: [
        for (final row in rows)
          DirectEmailMapper.listItem(
            row,
            resolveFolder: resolveFolder,
            accountId: accountId,
          ),
      ],
      page: page,
      pageSize: pageSize,
      total: total,
    );
  }

  // --- One mail ----------------------------------------------------------------

  Future<Email> getMail(
    String id, {
    required MailFolder Function(String folderId) resolveFolder,
    bool allowRemoteImages = false,
  }) async {
    var row = _requireMessage(id);
    if (!row.bodyLoaded) {
      try {
        await _withEngine(
          (engine, _) => engine.ensureBody(id),
          userInitiated: true,
        );
      } on DirectMailException catch (error) {
        // Gone from the server: let the next pass drop the stored row.
        if (error.kind == DirectErrorKind.mailNotFound) {
          _syncSoon(row.folderId);
        }
        rethrow;
      }
      row = _requireMessage(id);
    }
    final body = store.body(accountId, id);
    if (body == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    return DirectEmailMapper.detail(
      row,
      body,
      store.parts(accountId, id),
      resolveFolder: resolveFolder,
      accountId: accountId,
      allowRemoteImages: allowRemoteImages,
    );
  }

  /// The whole message as the server holds it (headers, parsed).
  Future<RemoteMessage> _fetchWhole(MessageRow row) {
    final uid = row.uid;
    final folder = store.folder(accountId, row.folderId);
    if (uid == null || folder == null) {
      throw DirectMailException(DirectErrorKind.mailNotFound);
    }
    return _run((imap) async {
      await imap.select(folder.path);
      return imap.fetchFull(folder.path, uid);
    }, userInitiated: true);
  }

  Future<List<MailHeaderEntry>> getMailHeaders(String id) async {
    final whole = await _fetchWhole(_requireMessage(id));
    final headers = whole.mime?.headers ?? const [];
    return [
      for (final header in headers)
        MailHeaderEntry(name: header.name, value: header.value ?? ''),
    ];
  }

  Future<String> getMailSource(String id) async {
    final whole = await _fetchWhole(_requireMessage(id));
    final mime = whole.mime;
    if (mime == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    return mime.renderMessage();
  }

  /// Signatures are detected and shown, but not verified: there is no
  /// certificate store behind a direct account, so the honest answer is
  /// "could not be verified".
  Future<MailSignatureVerification> getMailSignature(String id) async {
    _requireMessage(id);
    String standard = 'SMime';
    final json = store.body(accountId, id)?.securityJson;
    if (json != null) {
      try {
        final signed = (jsonDecode(json) as Map<String, dynamic>)['signed'];
        if (signed == 'OpenPgp') standard = 'OpenPgp';
      } catch (_) {
        // Keep the default.
      }
    }
    return MailSignatureVerification(
      standard: standard,
      status: 'Unverifiable',
      signers: const [],
    );
  }

  Future<Uint8List> downloadAttachment(
    String mailId,
    String attachmentId,
  ) async {
    final row = _requireMessage(mailId);
    final whole = await _fetchWhole(row);
    final mime = whole.mime;
    final bytes = mime == null
        ? null
        : MimeProcessor.partBytes(mime, attachmentId);
    if (bytes == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    return bytes;
  }

  // --- Conversations ---------------------------------------------------------------

  Future<ConversationListPage> getConversations({
    int page = 1,
    int pageSize = 50,
  }) async {
    final threads = store.threads(
      accountId,
      offset: (page - 1) * pageSize,
      limit: pageSize,
    );
    final items = <ConversationSummary>[];
    for (final thread in threads) {
      final messages = store.threadMessages(accountId, thread.threadId);
      if (messages.isEmpty) continue;
      final people = <String>{};
      for (final message in messages) {
        final who = message.fromName.isNotEmpty
            ? message.fromName
            : message.fromAddress;
        if (who.isNotEmpty) people.add(who);
      }
      items.add(
        ConversationSummary(
          id: thread.threadId,
          subject: messages.last.subject,
          participants: people.take(5).toList(),
          messageCount: messages.length,
          unreadCount: messages.where((m) => !m.isRead).length,
          hasAttachments: messages.any((m) => m.hasAttachments),
          startedAt: DateTime.fromMillisecondsSinceEpoch(thread.startedMs),
          lastMessageAt: DateTime.fromMillisecondsSinceEpoch(thread.lastMs),
        ),
      );
    }
    return ConversationListPage(
      items: items,
      page: page,
      pageSize: pageSize,
      total: store.threadCount(accountId),
    );
  }

  ApiConversation _conversation(String id, {required bool withBodies}) {
    final messages = store.threadMessages(accountId, id);
    if (messages.isEmpty) {
      throw DirectMailException(DirectErrorKind.mailNotFound);
    }
    return ApiConversation(
      id: id,
      subject: messages.last.subject,
      messageIds: [for (final m in messages) m.localId],
      messages: [
        for (final m in messages)
          DirectEmailMapper.conversationMessage(
            m,
            withBodies ? store.body(accountId, m.localId) : null,
          ),
      ],
    );
  }

  Future<ApiConversation> getConversation(String id) async =>
      _conversation(id, withBodies: false);

  /// The thread with bodies. Bodies not stored yet are fetched together on
  /// one connection; when the server cannot be reached the thread still
  /// opens, with what is stored.
  Future<ApiConversation> getConversationWithBodies(String id) async {
    final messages = store.threadMessages(accountId, id);
    final missing = [
      for (final m in messages.reversed)
        if (!m.bodyLoaded) m.localId,
    ].take(30).toList();
    if (missing.isNotEmpty) {
      try {
        await _withEngine((engine, _) async {
          for (final localId in missing) {
            try {
              await engine.ensureBody(localId);
            } on DirectMailException catch (error) {
              if (error.kind != DirectErrorKind.mailNotFound) rethrow;
            }
          }
        }, userInitiated: true);
      } on DirectMailException {
        // Show what is stored.
      }
    }
    return _conversation(id, withBodies: true);
  }

  Email mapConversationMessage(
    Map<String, dynamic> item,
    MailFolder Function(String folderId) resolveFolder,
  ) => DirectEmailMapper.fromConversationMessage(
    item,
    resolveFolder: resolveFolder,
    accountId: accountId,
  );
}
