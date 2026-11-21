import 'direct_store.dart';
import 'mail_threading.dart';

/// Puts a message into a conversation, the way the backend's
/// `ConversationService` does:
///
/// 1. messages linked through Message-ID / In-Reply-To / References share a
///    conversation, whichever arrives first; conversations that turn out to
///    be one are merged;
/// 2. otherwise, a message with the same normalised subject, within 30 days
///    of an existing conversation and sharing a participant other than the
///    mailbox owner, joins that conversation;
/// 3. otherwise it starts a new one.
class ThreadAssigner {
  ThreadAssigner(this._store);

  final DirectStore _store;

  /// Subject-only matches must be this close in time.
  static const subjectFallbackWindow = Duration(days: 30);

  /// Returns the thread of the message; [localId] is excluded from the
  /// lookups so a message never links to itself.
  String assign(
    String accountId, {
    required String localId,
    required String messageId,
    required String inReplyTo,
    required String references,
    required String subject,
    required Iterable<String> participants,
    required int sentMs,
    required String ownAddress,
  }) {
    final normalizedSubject = MailThreading.normalizeSubject(subject);
    final refs = MailThreading.parseReferences(references);
    final normalizedMessageId = MailThreading.normalizeMessageId(messageId);
    final normalizedInReplyTo = MailThreading.normalizeMessageId(inReplyTo);

    final keys = <String>{
      ...refs,
      if (normalizedInReplyTo.isNotEmpty) normalizedInReplyTo,
    };
    final linked = _store.threadsLinkedTo(
      accountId,
      keys: keys,
      messageId: normalizedMessageId,
      exceptLocalId: localId,
    );

    final String? existing = linked.isNotEmpty
        ? linked.first
        : _bySubject(
            accountId,
            normalizedSubject: normalizedSubject,
            participants: participants,
            sentMs: sentMs,
            ownAddress: ownAddress,
          );

    if (existing == null) {
      return _store.createThread(
        accountId,
        normalizedSubject: normalizedSubject,
        atMs: sentMs,
      );
    }
    _store.setThreadSubject(accountId, existing, normalizedSubject);
    if (linked.length > 1) {
      _store.mergeThreads(accountId, existing, linked.skip(1));
    }
    _store.widenThread(accountId, existing, sentMs);
    return existing;
  }

  String? _bySubject(
    String accountId, {
    required String normalizedSubject,
    required Iterable<String> participants,
    required int sentMs,
    required String ownAddress,
  }) {
    if (normalizedSubject.isEmpty) return null;
    final own = ownAddress.trim().toLowerCase();
    final wanted = {
      for (final p in participants)
        if (p.trim().isNotEmpty && p.trim().toLowerCase() != own)
          p.trim().toLowerCase(),
    };
    if (wanted.isEmpty) return null;
    final window = subjectFallbackWindow.inMilliseconds;
    final candidates = _store.threadsBySubject(
      accountId,
      normalizedSubject,
      fromMs: sentMs - window,
      toMs: sentMs + window,
    );
    for (final candidate in candidates) {
      final present = _store.threadParticipants(accountId, candidate.threadId);
      if (present.any(wanted.contains)) return candidate.threadId;
    }
    return null;
  }
}
