part of '../direct_mail_gateway.dart';

/// Writing mail: sending, drafts and the reply/forward starting points.
///
/// A send is recorded in the send journal before anything goes out, keyed by
/// the idempotency key the app supplies. That record is what makes retries
/// safe: a send that already succeeded answers with its earlier result, and a
/// send whose outcome is unknown ([DirectErrorKind.deliveryUncertain]) is
/// refused rather than repeated, because it may already have been delivered.
mixin _DirectComposeApi
    on _DirectGatewayBase, _DirectMailApi, _DirectActionApi {
  static const _smtpSizeKey = 'smtp_max_size';

  DirectSendJournal get _journal => DirectSendJournal(store);

  // --- Limits --------------------------------------------------------------------------

  /// Attachments must fit the message size the outgoing server announced,
  /// with room for the transfer encoding (base64 adds a third). Without an
  /// announcement a size every common server accepts is assumed.
  ComposeLimits _limits() {
    final announced = int.tryParse(
      store.setting(accountId, _smtpSizeKey) ?? '',
    );
    final bytes = announced == null || announced <= 0
        ? 18 * 1024 * 1024
        : min((announced * 0.72).floor(), 48 * 1024 * 1024);
    return ComposeLimits(
      maxAttachmentBytes: bytes,
      maxMessageAttachmentBytes: bytes,
      maxAttachmentCount: 25,
    );
  }

  Future<ComposeLimits> getComposeLimits() async => _limits();

  void _checkAttachments(List<Attachment> attachments) {
    final limits = _limits();
    final real = [
      for (final a in attachments)
        if (a.bytes != null) a,
    ];
    if (real.length > limits.maxAttachmentCount) {
      throw const ApiException(status: 413, code: 'too_many_attachments');
    }
    if (real.any((a) => a.bytes!.length > limits.maxAttachmentBytes) ||
        real.fold<int>(0, (sum, a) => sum + a.bytes!.length) >
            limits.maxMessageAttachmentBytes) {
      throw const ApiException(status: 413, code: 'attachment_too_large');
    }
  }

  // --- Building ---------------------------------------------------------------------------

  ({String address, String name, String? replyTo}) _sender(String? identityId) {
    if (identityId == null) {
      return (address: config.email, name: config.displayName, replyTo: null);
    }
    final identity = DirectMetaStore(store)
        .identities(accountId)
        .where((i) => i.id == identityId)
        .firstOrNull;
    if (identity == null) {
      throw const ApiException(status: 404, code: 'identity_not_found');
    }
    return (
      address: identity.email,
      name: identity.displayName.isEmpty
          ? config.displayName
          : identity.displayName,
      replyTo: identity.replyTo,
    );
  }

  ComposedMessage _build({
    required List<String> to,
    required List<String> cc,
    required List<String> bcc,
    required String subject,
    required String bodyText,
    String? bodyHtml,
    required List<Attachment> attachments,
    String? replySourceMailId,
    String? identityId,
    bool requestReadReceipt = false,
    bool isDraft = false,
  }) {
    _checkAttachments(attachments);
    final sender = _sender(identityId);
    final source = replySourceMailId == null
        ? null
        : store.message(accountId, replySourceMailId);
    final thread = source == null || source.messageId.isEmpty
        ? null
        : MailThreading.replyHeaders(source.messageId, source.references);
    return MessageComposer.compose(
      ComposeInput(
        fromAddress: sender.address,
        fromName: sender.name,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: subject,
        bodyText: bodyText,
        bodyHtml: bodyHtml,
        attachments: [
          for (final a in attachments)
            if (a.bytes != null)
              ComposeAttachment(
                name: a.name,
                bytes: a.bytes!,
                mimeType: a.mimeType,
              ),
        ],
        replyTo: sender.replyTo,
        inReplyTo: _bracketed(thread?.inReplyTo),
        references: _bracketed(thread?.references),
        requestReadReceipt: requestReadReceipt,
        isDraft: isDraft,
      ),
    );
  }

  /// `a b` → `<a> <b>`; null and blank stay null.
  static String? _bracketed(String? ids) {
    final list = [
      for (final id in (ids ?? '').split(' '))
        if (id.isNotEmpty) '<$id>',
    ];
    return list.isEmpty ? null : list.join(' ');
  }

  // --- Sending -----------------------------------------------------------------------------------

  Future<SendResult> sendMail({
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
    bool requestReadReceipt = false,
    required String idempotencyKey,
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final message = _build(
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      bodyText: bodyText,
      bodyHtml: bodyHtml,
      attachments: attachments,
      replySourceMailId: replySourceMailId,
      identityId: identityId,
      requestReadReceipt: requestReadReceipt,
    );
    final delivered = await _deliver(
      idempotencyKey,
      message,
      subject: subject,
      replySourceMailId: replySourceMailId,
      onProgress: onProgress,
      abort: abortTrigger,
    );
    return SendResult(
      sent: true,
      sentCopySaved: delivered.copySaved,
      warning: delivered.copySaved ? null : delivered.warning,
      mailId: delivered.localId,
      conversationId: delivered.threadId,
    );
  }

  final Set<String> _sending = {};

  /// Records, submits and files one message. Throws what the SMTP exchange
  /// threw; once it has returned, the message is out.
  Future<({String? localId, String? threadId, bool copySaved, String? warning})>
  _deliver(
    String key,
    ComposedMessage message, {
    required String subject,
    String? replySourceMailId,
    void Function(int sent, int total)? onProgress,
    Future<void>? abort,
  }) async {
    _journal.tidy(accountId);
    final prior = _journal.find(accountId, key);
    if (prior != null) {
      switch (prior.state) {
        case SendState.sent:
          return (
            localId: prior.localId,
            threadId: prior.threadId,
            copySaved: prior.copySaved,
            warning: null,
          );
        case SendState.uncertain:
          throw DirectMailException(DirectErrorKind.deliveryUncertain);
        case SendState.sending:
          if (_sending.contains(key)) {
            throw const ApiException(status: 409, code: 'send_in_progress');
          }
          // Left over from a process that went away mid-send.
          _journal.markUncertain(accountId, key);
          throw DirectMailException(DirectErrorKind.deliveryUncertain);
        case SendState.failed:
          break;
      }
    }
    final refusal = _smtpRefusal;
    if (refusal != null) throw refusal;

    _journal.begin(accountId, key, message.messageId);
    _sending.add(key);
    try {
      final sender = runtime.smtpFactory(
        config.smtp,
        runtime.credentials.effectiveSmtpPassword,
        _domainOf(config.email),
      );
      await sender.send(message, onProgress: onProgress, abort: abort);
      final announced = sender.maxMessageSize;
      if (announced != null) {
        store.putSetting(accountId, _smtpSizeKey, '$announced');
      }
    } on http.RequestAbortedException {
      _journal.markFailed(accountId, key);
      rethrow;
    } catch (error) {
      final mapped = DirectMailException.from(error);
      if (mapped.kind == DirectErrorKind.deliveryUncertain) {
        _journal.markUncertain(accountId, key);
      } else {
        _journal.markFailed(accountId, key);
      }
      if (mapped.category == ApiErrorCategory.authentication) {
        // Do not try the same refused password again and again: servers
        // answer that with a block.
        _smtpRefusal = mapped;
        _emit(const GatewayEvent(GatewayEventKind.needsReauthentication));
      }
      if (identical(mapped, error)) rethrow;
      throw mapped;
    } finally {
      _sending.remove(key);
    }

    final filed = await _fileSentCopy(message);
    _journal.markSent(
      accountId,
      key,
      localId: filed.localId,
      threadId: filed.threadId,
      copySaved: filed.saved,
    );
    if (replySourceMailId != null) {
      await _markReplied(replySourceMailId, subject);
    }
    return (
      localId: filed.localId,
      threadId: filed.threadId,
      copySaved: filed.saved,
      warning: filed.warning,
    );
  }

  static String _domainOf(String email) {
    final at = email.lastIndexOf('@');
    return at < 0 || at == email.length - 1
        ? 'localhost'
        : email.substring(at + 1);
  }

  /// Servers that file their own copy of what is sent through them; adding
  /// another would show every mail twice.
  static bool _filesOwnCopy(String smtpHost) {
    final host = smtpHost.toLowerCase();
    return host == 'smtp.gmail.com' ||
        host == 'smtp.googlemail.com' ||
        host == 'smtp-mail.outlook.com' ||
        host.endsWith('.office365.com');
  }

  /// Puts the sent message in the Sent folder. A failure here never makes the
  /// send fail: the mail is out, only its copy is missing.
  Future<({String? localId, String? threadId, bool saved, String? warning})>
  _fileSentCopy(ComposedMessage message) async {
    try {
      final serverFiles = _filesOwnCopy(config.smtp.host);
      if (!serverFiles && !config.saveSentCopy) {
        return (localId: null, threadId: null, saved: false, warning: null);
      }
      // A server that files its own copy needs no folder made for it.
      final sent = serverFiles
          ? store.folderByRole(accountId, FolderRole.sent)
          : await _roleFolder(FolderRole.sent);
      if (!serverFiles) {
        await _run(
          (imap) => imap.append(
            sent!.path,
            message.sourceForCopy,
            flags: {ImapFlags.seen},
            date: _clock(),
          ),
          userInitiated: true,
        );
      }
      if (sent == null) {
        return (localId: null, threadId: null, saved: true, warning: null);
      }
      if (sent.lastSyncMs != null) await _quietSync(sent.folderId);
      final id = MailThreading.normalizeMessageId(message.messageId);
      final row = store
          .messagesByMessageId(accountId, id)
          .where((m) => m.folderId == sent.folderId)
          .firstOrNull;
      return (
        localId: row?.localId,
        threadId: row?.threadId,
        saved: true,
        warning: null,
      );
    } on DirectMailException {
      return (
        localId: null,
        threadId: null,
        saved: false,
        warning: 'sent_copy_failed',
      );
    }
  }

  /// Tells the mailbox which mail was answered or forwarded (the `\Answered`
  /// and `$Forwarded` flags other mail apps show too). Best effort.
  Future<void> _markReplied(String sourceMailId, String subject) async {
    final row = store.message(accountId, sourceMailId);
    final folder = row == null ? null : store.folder(accountId, row.folderId);
    if (row == null || folder == null || row.uid == null) return;
    final forwarded = RegExp(
      r'^\s*(fwd?|ilt|iletildi)\s*:',
      caseSensitive: false,
    ).hasMatch(subject);
    final flag = forwarded ? ImapFlags.forwarded : ImapFlags.answered;
    try {
      await _run((imap) async {
        await _selectChecked(imap, folder);
        await imap.storeFlags(folder.path, [row.uid!], add: {flag});
      });
      store.updateFlags(
        accountId,
        row.localId,
        isRead: row.isRead,
        isFlagged: row.isFlagged,
        isAnswered: row.isAnswered || !forwarded,
        isDraft: row.isDraft,
        isForwarded: row.isForwarded || forwarded,
        isDeleted: row.isDeleted,
        keywords: row.keywords,
      );
    } on DirectMailException {
      // The mail went out; the flag can wait for the next time.
    }
  }

  // --- Drafts ----------------------------------------------------------------------------------------

  FolderRow _requireDraft(MessageRow row) {
    final folder = store.folder(accountId, row.folderId);
    if (folder == null || folder.role != FolderRole.drafts) {
      throw const ApiException(status: 422, code: 'mail_not_draft');
    }
    return folder;
  }

  /// Files [message] in Drafts and returns the id it got locally, once the
  /// folder lists it.
  Future<String?> _appendDraft(ComposedMessage message) async {
    final drafts = await _roleFolder(FolderRole.drafts);
    await _run(
      (imap) => imap.append(
        drafts.path,
        message.sourceForCopy,
        flags: {ImapFlags.draft, ImapFlags.seen},
        date: _clock(),
      ),
      userInitiated: true,
    );
    await _quietSync(drafts.folderId);
    final id = MailThreading.normalizeMessageId(message.messageId);
    return store
        .messagesByMessageId(accountId, id)
        .where((m) => m.folderId == drafts.folderId)
        .firstOrNull
        ?.localId;
  }

  Future<DraftResult> createDraft({
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    String subject = '',
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
  }) async {
    final message = _build(
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      bodyText: bodyText,
      bodyHtml: bodyHtml,
      attachments: attachments,
      replySourceMailId: replySourceMailId,
      identityId: identityId,
      isDraft: true,
    );
    return DraftResult(created: true, mailId: await _appendDraft(message));
  }

  /// IMAP cannot edit a message, so the new version is filed first and the
  /// old one removed after it; the new id replaces the old.
  Future<DraftResult> updateDraft(
    String id, {
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    String subject = '',
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
  }) async {
    final old = _requireMessage(id);
    final folder = _requireDraft(old);
    final message = _build(
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      bodyText: bodyText,
      bodyHtml: bodyHtml,
      attachments: attachments,
      replySourceMailId: replySourceMailId,
      identityId: identityId,
      isDraft: true,
    );
    final newId = await _appendDraft(message);
    String? warning;
    try {
      await _removeFromServer(folder, old);
    } on DirectMailException {
      warning = 'draft_old_copy_remains';
    }
    return DraftResult(created: false, mailId: newId, warning: warning);
  }

  Future<void> _removeFromServer(FolderRow folder, MessageRow row) async {
    final uid = row.uid;
    if (uid == null) {
      store.deleteMessage(accountId, row.localId);
      return;
    }
    await _run((imap) async {
      await _selectChecked(imap, folder);
      await imap.expunge(folder.path, [uid]);
    }, userInitiated: true);
    store.transaction(() {
      store.deleteMessage(accountId, row.localId);
      store.adjustFolderCounts(
        accountId,
        folder.folderId,
        existsDelta: -1,
        unseenDelta: row.isRead ? 0 : -1,
      );
    });
  }

  Future<void> deleteDraft(String id) async {
    final row = _requireMessage(id);
    await _removeFromServer(_requireDraft(row), row);
  }

  Future<Email> getDraft(
    String id, {
    required MailFolder Function(String folderId) resolveFolder,
  }) async {
    _requireDraft(_requireMessage(id));
    return getMail(id, resolveFolder: resolveFolder);
  }

  /// Sends the draft as it is stored on the server, with a fresh `Date`, then
  /// removes it. A draft left behind after the mail went out is reported as
  /// such, never as a failed send.
  Future<SendDraftResult> sendDraft(
    String id, {
    required String idempotencyKey,
  }) async {
    final prior = _journal.find(accountId, idempotencyKey);
    if (prior != null && prior.state == SendState.sent) {
      // A retry of a send that went through: answered from the journal, even
      // when the draft is gone by now.
      return SendDraftResult(
        sent: true,
        sentCopySaved: prior.copySaved,
        draftRemoved: store.message(accountId, id) == null,
      );
    }
    final row = _requireMessage(id);
    final folder = _requireDraft(row);
    final whole = await _fetchWhole(row);
    final mime = whole.mime;
    if (mime == null) {
      throw DirectMailException(DirectErrorKind.mailNotFound);
    }
    final delivered = await _deliver(
      idempotencyKey,
      _fromStoredDraft(mime),
      subject: row.subject,
    );
    var removed = true;
    try {
      final current = store.message(accountId, id);
      if (current != null) await _removeFromServer(folder, current);
    } on DirectMailException {
      removed = false;
    }
    return SendDraftResult(
      sent: true,
      sentCopySaved: delivered.copySaved,
      draftRemoved: removed,
      warning: removed ? null : 'draft_not_removed',
    );
  }

  /// The wire form of a stored draft: no `Bcc` header, today's date, and the
  /// envelope taken from its own recipient headers.
  ComposedMessage _fromStoredDraft(MimeMessage mime) {
    final headers = MimeProcessor.parseHeaders(mime);
    final recipients = <String>[];
    final seen = <String>{};
    for (final r in [...headers.to, ...headers.cc, ...headers.bcc]) {
      if (seen.add(r.address.toLowerCase())) recipients.add(r.address);
    }
    if (recipients.isEmpty) {
      throw DirectMailException(DirectErrorKind.smtpRecipientRejected);
    }
    final from = headers.fromAddress.isEmpty
        ? config.email
        : headers.fromAddress;
    final date = DateCodec.encodeDate(_clock());
    mime.setHeader('Date', date);
    final withBcc = mime.renderMessage();
    final messageId = headers.messageId.isEmpty
        ? MessageComposer.newMessageId(from)
        : '<${headers.messageId}>';
    return ComposedMessage(
      messageId: messageId,
      source: _withoutBcc(withBcc),
      sourceForCopy: withBcc,
      envelopeFrom: from,
      envelopeRecipients: recipients,
    );
  }

  static String _withoutBcc(String message) {
    final end = message.indexOf('\r\n\r\n');
    if (end < 0) return message;
    final head = message.substring(0, end + 2);
    final stripped = head.replaceAll(
      RegExp(
        r'^bcc:.*\r\n(?:[ \t].*\r\n)*',
        multiLine: true,
        caseSensitive: false,
      ),
      '',
    );
    return stripped + message.substring(end + 2);
  }

  // --- Starting points for replies and forwards ----------------------------------------------

  /// Who a reply goes to, the subject and the threading, worked out on this
  /// device from the stored message (the same rules the backend applies).
  Future<ComposePrefill> getComposePrefill(
    String sourceMailId,
    String kind,
  ) async {
    if (kind != 'reply' && kind != 'reply-all' && kind != 'forward') {
      throw ArgumentError('Unknown compose kind: $kind');
    }
    final row = _requireMessage(sourceMailId);
    final from = [MailRecipient(row.fromAddress, row.fromName)];
    final own = {
      config.email,
      for (final i in DirectMetaStore(store).identities(accountId)) i.email,
    };
    final ResolvedRecipients people = switch (kind) {
      'reply' => MailRecipients.reply(from: from, replyTo: row.replyTo),
      'reply-all' => MailRecipients.replyAll(
        from: from,
        to: row.to,
        replyTo: row.replyTo,
        cc: row.cc,
        ownAddresses: own,
      ),
      _ => const ResolvedRecipients(),
    };
    final thread = MailThreading.replyHeaders(row.messageId, row.references);
    final attachments = kind == 'forward'
        ? [
            for (final part in store.parts(accountId, sourceMailId))
              if (!part.isInline)
                Attachment(
                  id: part.partId,
                  name: part.filename,
                  sizeBytes: part.size,
                  mimeType: part.mime,
                ),
          ]
        : const <Attachment>[];
    return ComposePrefill(
      sourceMailId: sourceMailId,
      to: [for (final r in people.to) r.address],
      cc: [for (final r in people.cc) r.address],
      suggestedSubject: _prefixedSubject(
        row.subject,
        forward: kind == 'forward',
      ),
      inReplyToMessageId: _bracketed(thread.inReplyTo),
      references: _bracketed(thread.references),
      originalFrom: row.fromName.isEmpty
          ? row.fromAddress
          : '${row.fromName} <${row.fromAddress}>',
      originalDate: DateTime.fromMillisecondsSinceEpoch(row.dateMs),
      originalSubject: row.subject,
      attachments: attachments,
    );
  }

  static String _prefixedSubject(String subject, {required bool forward}) {
    final trimmed = subject.trim();
    final already = forward
        ? RegExp(r'^(fwd?|ilt|iletildi)\s*:', caseSensitive: false)
        : RegExp(r'^(re|yan|yanıt|cvp)\s*:', caseSensitive: false);
    if (already.hasMatch(trimmed)) return trimmed;
    return '${forward ? 'Fwd' : 'Re'}: $trimmed';
  }
}
