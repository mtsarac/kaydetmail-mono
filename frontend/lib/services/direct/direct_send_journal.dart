import 'direct_store.dart';

/// What happened to one send attempt.
enum SendState {
  /// Handed to the SMTP exchange; not known to have finished.
  sending,

  /// The server accepted the message.
  sent,

  /// The server refused it, or it never got far enough to matter: nothing
  /// was delivered and trying again is safe.
  failed,

  /// The data went out but no answer came: the message may or may not have
  /// been delivered. Never repeated automatically.
  uncertain;

  static SendState fromName(String name) => values.firstWhere(
    (state) => state.name == name,
    orElse: () => SendState.uncertain,
  );
}

class SendRecord {
  const SendRecord({
    required this.key,
    required this.state,
    required this.messageId,
    this.localId,
    this.threadId,
    this.copySaved = false,
    required this.startedMs,
    required this.updatedMs,
  });

  final String key;
  final SendState state;
  final String messageId;
  final String? localId;
  final String? threadId;
  final bool copySaved;
  final int startedMs;
  final int updatedMs;
}

/// The device's record of send attempts. This is what makes "send" safe to
/// retry: a key that already succeeded answers with the earlier result, and
/// a key whose outcome is unknown is refused rather than risk a duplicate.
class DirectSendJournal {
  DirectSendJournal(this._store);

  final DirectStore _store;

  /// An attempt still `sending` after this long was cut off (the app was
  /// closed mid-send): its outcome is unknown.
  static const staleAfter = Duration(minutes: 3);

  SendRecord? find(String accountId, String key) {
    final rows = _store.db.select(
      'SELECT * FROM d_sends WHERE account_id = ? AND send_key = ?',
      [accountId, key],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SendRecord(
      key: key,
      state: SendState.fromName(row['state'] as String),
      messageId: row['message_id'] as String,
      localId: row['local_id'] as String?,
      threadId: row['thread_id'] as String?,
      copySaved: (row['copy_saved'] as int) != 0,
      startedMs: row['started_ms'] as int,
      updatedMs: row['updated_ms'] as int,
    );
  }

  /// Records that an attempt starts. [messageId] is kept so a retry after a
  /// definite failure sends the same message.
  void begin(String accountId, String key, String messageId) {
    final nowMs = _store.now.millisecondsSinceEpoch;
    _store.db.execute(
      '''
      INSERT INTO d_sends (account_id, send_key, state, message_id,
        started_ms, updated_ms) VALUES (?,?,?,?,?,?)
      ON CONFLICT(account_id, send_key) DO UPDATE SET state = excluded.state,
        message_id = excluded.message_id, started_ms = excluded.started_ms,
        updated_ms = excluded.updated_ms''',
      [accountId, key, SendState.sending.name, messageId, nowMs, nowMs],
    );
  }

  void _set(String accountId, String key, SendState state) => _store.db.execute(
    'UPDATE d_sends SET state = ?, updated_ms = ? '
    'WHERE account_id = ? AND send_key = ?',
    [state.name, _store.now.millisecondsSinceEpoch, accountId, key],
  );

  void markSent(
    String accountId,
    String key, {
    String? localId,
    String? threadId,
    bool copySaved = false,
  }) => _store.db.execute(
    '''
    UPDATE d_sends SET state = ?, local_id = ?, thread_id = ?, copy_saved = ?,
      updated_ms = ? WHERE account_id = ? AND send_key = ?''',
    [
      SendState.sent.name,
      localId,
      threadId,
      copySaved ? 1 : 0,
      _store.now.millisecondsSinceEpoch,
      accountId,
      key,
    ],
  );

  void markFailed(String accountId, String key) =>
      _set(accountId, key, SendState.failed);

  void markUncertain(String accountId, String key) =>
      _set(accountId, key, SendState.uncertain);

  /// Turns attempts left `sending` by a process that went away into
  /// `uncertain`, and forgets old finished ones.
  void tidy(String accountId) {
    final nowMs = _store.now.millisecondsSinceEpoch;
    _store.db.execute(
      'UPDATE d_sends SET state = ?, updated_ms = ? '
      'WHERE account_id = ? AND state = ? AND started_ms < ?',
      [
        SendState.uncertain.name,
        nowMs,
        accountId,
        SendState.sending.name,
        nowMs - staleAfter.inMilliseconds,
      ],
    );
    _store.db.execute(
      'DELETE FROM d_sends WHERE account_id = ? AND state IN (?, ?) '
      'AND updated_ms < ?',
      [
        accountId,
        SendState.sent.name,
        SendState.failed.name,
        nowMs - const Duration(days: 30).inMilliseconds,
      ],
    );
  }
}
