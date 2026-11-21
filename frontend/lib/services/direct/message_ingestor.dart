import 'direct_store.dart';
import 'imap_flags.dart';
import 'imap_models.dart';
import 'mime_processor.dart';
import 'thread_assigner.dart';

/// Turns a header-level fetch into a stored message row, with a conversation.
class MessageIngestor {
  MessageIngestor(this._store) : _threads = ThreadAssigner(_store);

  final DirectStore _store;
  final ThreadAssigner _threads;

  /// Stores [remote] as a message of [folder]. A UID already stored is
  /// updated in place. [rebindLocalId] writes over a row left behind by a
  /// UIDVALIDITY reset so its pins, labels and snoozes follow the message.
  ({String localId, bool isNew}) ingest(
    FolderRow folder,
    RemoteMessage remote, {
    required String ownAddress,
    String? rebindLocalId,
  }) {
    final mime = remote.mime;
    final h = mime == null ? null : MimeProcessor.parseHeaders(mime);
    final flags = ImapFlags.fromWire(remote.flags);
    final internalMs = remote.internalDate?.toUtc().millisecondsSinceEpoch;
    final nowMs = _store.now.millisecondsSinceEpoch;
    final sortMs = internalMs ?? h?.dateMs ?? nowMs;
    final dateMs = h?.dateMs ?? sortMs;

    final existing = _store.messageByUid(
      folder.accountId,
      folder.folderId,
      remote.uid,
    );
    final reuse =
        existing ??
        (rebindLocalId == null
            ? null
            : _store.message(folder.accountId, rebindLocalId));
    final localId = existing?.localId ?? rebindLocalId ?? _store.newId('d');

    var threadId = reuse?.threadId ?? '';
    if (threadId.isEmpty || _store.thread(folder.accountId, threadId) == null) {
      threadId = _threads.assign(
        folder.accountId,
        localId: localId,
        messageId: h?.messageId ?? '',
        inReplyTo: h?.inReplyTo ?? '',
        references: h?.references ?? '',
        subject: h?.subject ?? '',
        participants: [
          if (h != null) ...[
            h.fromAddress,
            for (final r in [...h.to, ...h.cc, ...h.bcc, ...h.replyTo])
              r.address,
          ],
        ],
        sentMs: sortMs,
        ownAddress: ownAddress,
      );
    }

    final draft = MessageDraft(
      accountId: folder.accountId,
      folderId: folder.folderId,
      uid: remote.uid,
      uidValidity: folder.uidValidity,
      localId: localId,
      messageId: h?.messageId ?? '',
      inReplyTo: h?.inReplyTo ?? '',
      references: h?.references ?? '',
      threadId: threadId,
      subject: h?.subject ?? '',
      fromName: h?.fromName ?? '',
      fromAddress: h?.fromAddress ?? '',
      to: h?.to ?? const [],
      cc: h?.cc ?? const [],
      bcc: h?.bcc ?? const [],
      replyTo: h?.replyTo ?? const [],
      sortMs: sortMs,
      dateMs: dateMs,
      internalMs: internalMs,
      size: remote.size ?? 0,
      isRead: flags.isRead,
      isFlagged: flags.isFlagged,
      isAnswered: flags.isAnswered,
      isDraft: flags.isDraft,
      isForwarded: flags.isForwarded,
      isDeleted: flags.isDeleted,
      keywords: flags.keywords,
      hasAttachments: reuse?.hasAttachments ?? h?.mayHaveAttachments ?? false,
    );

    if (existing != null) {
      _store.upsertMessage(draft);
      return (localId: localId, isNew: false);
    }
    if (rebindLocalId != null && reuse != null) {
      _store.rebindMessage(localId, draft);
      return (localId: localId, isNew: false);
    }
    _store.upsertMessage(draft);
    return (localId: localId, isNew: true);
  }
}
