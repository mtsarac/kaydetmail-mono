import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';

import '../api_exception.dart';
import 'direct_store.dart';

/// A scheduled send as stored.
class ScheduledRow {
  const ScheduledRow({
    required this.id,
    required this.createKey,
    required this.revision,
    required this.status,
    required this.to,
    required this.cc,
    required this.bcc,
    required this.subject,
    required this.bodyText,
    required this.bodyHtml,
    required this.replySource,
    required this.identityId,
    required this.readReceipt,
    required this.sendAtMs,
    required this.createdMs,
    required this.attempts,
    required this.nextAttemptMs,
    required this.failureReason,
    required this.sentLocalId,
  });

  final String id;
  final String createKey;
  final int revision;

  /// `pending`, `sent`, `cancelled`, `failed` or `deliveryUnknown`.
  final String status;
  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String bodyText;
  final String? bodyHtml;
  final String? replySource;
  final String? identityId;
  final bool readReceipt;
  final int sendAtMs;
  final int createdMs;
  final int attempts;
  final int? nextAttemptMs;
  final String? failureReason;
  final String? sentLocalId;
}

class ScheduledFile {
  const ScheduledFile({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    this.content,
  });

  final String id;
  final String name;
  final String? mime;
  final int size;
  final Uint8List? content;
}

/// Scheduled sends of the local store.
class DirectScheduledStore {
  DirectScheduledStore(this._store);

  final DirectStore _store;
  CommonDatabase get _db => _store.db;

  static ApiException _error(int status, String code) =>
      ApiException(status: status, code: code);

  ScheduledRow _row(Row row) => ScheduledRow(
    id: row['scheduled_id'] as String,
    createKey: row['create_key'] as String,
    revision: row['revision'] as int,
    status: row['status'] as String,
    to: _list(row['to_json']),
    cc: _list(row['cc_json']),
    bcc: _list(row['bcc_json']),
    subject: row['subject'] as String,
    bodyText: row['body_text'] as String,
    bodyHtml: row['body_html'] as String?,
    replySource: row['reply_source'] as String?,
    identityId: row['identity_id'] as String?,
    readReceipt: (row['read_receipt'] as int) != 0,
    sendAtMs: row['send_at_ms'] as int,
    createdMs: row['created_ms'] as int,
    attempts: row['attempts'] as int,
    nextAttemptMs: row['next_attempt_ms'] as int?,
    failureReason: row['failure_reason'] as String?,
    sentLocalId: row['sent_local_id'] as String?,
  );

  static List<String> _list(Object? json) => [
    for (final e in jsonDecode(json as String) as List) e as String,
  ];

  ScheduledRow? find(String accountId, String id) {
    final rows = _db.select(
      'SELECT * FROM d_scheduled WHERE account_id = ? AND scheduled_id = ?',
      [accountId, id],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  ScheduledRow? findByKey(String accountId, String key) {
    final rows = _db.select(
      'SELECT * FROM d_scheduled WHERE account_id = ? AND create_key = ?',
      [accountId, key],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  ScheduledRow require(String accountId, String id) =>
      find(accountId, id) ?? (throw _error(404, 'scheduled_send_not_found'));

  /// What the list shows: pending, failed and unknown sends, and ones that
  /// went out in the last week.
  List<ScheduledRow> visible(String accountId) {
    final weekAgo =
        _store.now.millisecondsSinceEpoch -
        const Duration(days: 7).inMilliseconds;
    return [
      for (final row in _db.select(
        '''
        SELECT * FROM d_scheduled WHERE account_id = ? AND status <> 'cancelled'
          AND (status <> 'sent' OR send_at_ms > ?)
        ORDER BY send_at_ms, scheduled_id''',
        [accountId, weekAgo],
      ))
        _row(row),
    ];
  }

  /// Pending sends whose time has come.
  List<ScheduledRow> due(String accountId) {
    final nowMs = _store.now.millisecondsSinceEpoch;
    return [
      for (final row in _db.select(
        '''
        SELECT * FROM d_scheduled WHERE account_id = ? AND status = 'pending'
          AND send_at_ms <= ? AND COALESCE(next_attempt_ms, 0) <= ?
        ORDER BY send_at_ms, scheduled_id''',
        [accountId, nowMs, nowMs],
      ))
        _row(row),
    ];
  }

  /// When the earliest pending send is due, or null when none is.
  int? nextDueMs(String accountId) {
    final v = _db
        .select(
          '''
      SELECT MIN(MAX(send_at_ms, COALESCE(next_attempt_ms, 0))) AS v
      FROM d_scheduled WHERE account_id = ? AND status = 'pending' ''',
          [accountId],
        )
        .first['v'];
    return v as int?;
  }

  ScheduledRow create(
    String accountId, {
    required String createKey,
    required List<String> to,
    required List<String> cc,
    required List<String> bcc,
    required String subject,
    required String bodyText,
    String? bodyHtml,
    String? replySource,
    String? identityId,
    required bool readReceipt,
    required DateTime sendAt,
    required List<ScheduledFile> files,
  }) {
    final existing = findByKey(accountId, createKey);
    if (existing != null) return existing;
    final id = _store.newId('q');
    final nowMs = _store.now.millisecondsSinceEpoch;
    _store.transaction(() {
      _db.execute(
        '''
        INSERT INTO d_scheduled (account_id, scheduled_id, create_key, status,
          to_json, cc_json, bcc_json, subject, body_text, body_html,
          reply_source, identity_id, read_receipt, send_at_ms, created_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [
          accountId,
          id,
          createKey,
          'pending',
          jsonEncode(to),
          jsonEncode(cc),
          jsonEncode(bcc),
          subject,
          bodyText,
          bodyHtml,
          replySource,
          identityId,
          readReceipt ? 1 : 0,
          sendAt.toUtc().millisecondsSinceEpoch,
          nowMs,
        ],
      );
      for (final file in files) {
        putFile(accountId, id, file);
      }
    });
    return require(accountId, id);
  }

  void putFile(String accountId, String scheduledId, ScheduledFile file) {
    _db.execute('INSERT INTO d_scheduled_files VALUES (?,?,?,?,?,?,?)', [
      accountId,
      scheduledId,
      file.id.isEmpty ? _store.newId('x') : file.id,
      file.name,
      file.mime,
      file.size,
      file.content ?? Uint8List(0),
    ]);
  }

  List<ScheduledFile> files(
    String accountId,
    String scheduledId, {
    bool withContent = false,
  }) => [
    for (final row in _db.select(
      'SELECT * FROM d_scheduled_files WHERE account_id = ? AND scheduled_id = ? '
      'ORDER BY rowid',
      [accountId, scheduledId],
    ))
      ScheduledFile(
        id: row['file_id'] as String,
        name: row['name'] as String,
        mime: row['mime'] as String?,
        size: row['size'] as int,
        content: withContent ? row['content'] as Uint8List : null,
      ),
  ];

  void removeFiles(
    String accountId,
    String scheduledId, {
    Set<String>? except,
  }) {
    for (final file in files(accountId, scheduledId)) {
      if (except != null && except.contains(file.id)) continue;
      _db.execute(
        'DELETE FROM d_scheduled_files WHERE account_id = ? '
        'AND scheduled_id = ? AND file_id = ?',
        [accountId, scheduledId, file.id],
      );
    }
  }

  /// Replaces the content of a pending send and bumps its revision.
  void update(
    String accountId,
    String id, {
    required List<String> to,
    required List<String> cc,
    required List<String> bcc,
    required String subject,
    required String bodyText,
    String? bodyHtml,
    required DateTime sendAt,
  }) => _db.execute(
    '''
    UPDATE d_scheduled SET to_json = ?, cc_json = ?, bcc_json = ?, subject = ?,
      body_text = ?, body_html = ?, send_at_ms = ?, revision = revision + 1,
      attempts = 0, next_attempt_ms = NULL, failure_reason = NULL
    WHERE account_id = ? AND scheduled_id = ?''',
    [
      jsonEncode(to),
      jsonEncode(cc),
      jsonEncode(bcc),
      subject,
      bodyText,
      bodyHtml,
      sendAt.toUtc().millisecondsSinceEpoch,
      accountId,
      id,
    ],
  );

  void setStatus(
    String accountId,
    String id,
    String status, {
    String? failureReason,
    String? sentLocalId,
  }) => _db.execute(
    '''
    UPDATE d_scheduled SET status = ?, failure_reason = ?,
      sent_local_id = COALESCE(?, sent_local_id), next_attempt_ms = NULL
    WHERE account_id = ? AND scheduled_id = ?''',
    [status, failureReason, sentLocalId, accountId, id],
  );

  /// Another try later; the time to wait grows with every failed one.
  void retryLater(String accountId, String id, DateTime at, String reason) =>
      _db.execute(
        '''
        UPDATE d_scheduled SET attempts = attempts + 1, next_attempt_ms = ?,
          failure_reason = ?
        WHERE account_id = ? AND scheduled_id = ?''',
        [at.toUtc().millisecondsSinceEpoch, reason, accountId, id],
      );

  void delete(String accountId, String id) {
    _store.transaction(() {
      removeFiles(accountId, id);
      _db.execute(
        'DELETE FROM d_scheduled WHERE account_id = ? AND scheduled_id = ?',
        [accountId, id],
      );
    });
  }
}
