import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart';

import '../api_auth_service.dart' show MailSecurity;
import 'direct_account_setup.dart';
import 'imap_models.dart';
import 'mail_recipients.dart';

/// The device-side home of every direct account's mail: folders, message
/// headers, bodies, attachment metadata, threads and the queue of changes
/// still to be sent to the server.
///
/// It lives in the same encrypted SQLite file as the backend cache but in
/// tables of its own (`d_*`), so the backend cache is never touched. Unlike
/// that cache, nothing here is a disposable copy: a direct account's mailbox
/// is read from here first, offline included.
///
/// Every row carries `account_id`; removing an account deletes exactly its
/// rows ([removeAccount]).
class DirectStore {
  DirectStore(this._db, {String Function()? newId, DateTime Function()? clock})
    : _newId = newId ?? _randomId,
      _clock = clock ?? DateTime.now {
    _migrate();
  }

  final CommonDatabase _db;
  final String Function() _newId;
  final DateTime Function() _clock;

  CommonDatabase get db => _db;
  DateTime get now => _clock();

  static String _randomId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// A fresh id for a local row; `prefix` tells the kind apart in logs.
  String newId(String prefix) => '$prefix:${_newId()}';

  // --- Schema ------------------------------------------------------------

  /// Ordered, append-only. A shipped entry is never edited: changes go in a
  /// new entry so devices upgrade from any earlier version.
  static const List<List<String>> _migrations = [
    // 1 — accounts, folders, threads, messages, bodies, attachment parts.
    [
      '''
      CREATE TABLE d_accounts (
        account_id TEXT PRIMARY KEY,
        email TEXT NOT NULL,
        display_name TEXT NOT NULL,
        imap_host TEXT NOT NULL, imap_port INTEGER NOT NULL,
        imap_security TEXT NOT NULL, imap_user TEXT NOT NULL,
        smtp_host TEXT NOT NULL, smtp_port INTEGER NOT NULL,
        smtp_security TEXT NOT NULL, smtp_user TEXT NOT NULL,
        save_sent_copy INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'active',
        created_at INTEGER NOT NULL
      )''',
      '''
      CREATE TABLE d_folders (
        account_id TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        delimiter TEXT NOT NULL DEFAULT '',
        parent_folder_id TEXT,
        detected_role TEXT NOT NULL DEFAULT 'Custom',
        role_override TEXT,
        attributes TEXT NOT NULL DEFAULT '',
        available INTEGER NOT NULL DEFAULT 1,
        sync_enabled INTEGER NOT NULL DEFAULT 0,
        uid_validity INTEGER,
        uid_next INTEGER,
        highest_modseq INTEGER,
        remote_exists INTEGER,
        remote_unseen INTEGER,
        oldest_synced_uid INTEGER,
        backfill_complete INTEGER NOT NULL DEFAULT 0,
        last_sync_ms INTEGER,
        last_failure_ms INTEGER,
        last_failure_code TEXT,
        consecutive_failures INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account_id, folder_id)
      )''',
      'CREATE UNIQUE INDEX d_folders_path ON d_folders(account_id, path)',
      '''
      CREATE TABLE d_threads (
        account_id TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        normalized_subject TEXT NOT NULL,
        started_ms INTEGER NOT NULL,
        last_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, thread_id)
      )''',
      'CREATE INDEX d_threads_subject ON d_threads(account_id, normalized_subject, last_ms)',
      '''
      CREATE TABLE d_messages (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        uid INTEGER,
        uid_validity INTEGER,
        message_id TEXT NOT NULL DEFAULT '',
        in_reply_to TEXT NOT NULL DEFAULT '',
        refs TEXT NOT NULL DEFAULT '',
        thread_id TEXT NOT NULL DEFAULT '',
        subject TEXT NOT NULL DEFAULT '',
        from_name TEXT NOT NULL DEFAULT '',
        from_addr TEXT NOT NULL DEFAULT '',
        to_json TEXT NOT NULL DEFAULT '[]',
        cc_json TEXT NOT NULL DEFAULT '[]',
        bcc_json TEXT NOT NULL DEFAULT '[]',
        reply_to_json TEXT NOT NULL DEFAULT '[]',
        sort_ms INTEGER NOT NULL,
        date_ms INTEGER NOT NULL,
        internal_ms INTEGER,
        size INTEGER NOT NULL DEFAULT 0,
        is_read INTEGER NOT NULL DEFAULT 0,
        is_flagged INTEGER NOT NULL DEFAULT 0,
        is_answered INTEGER NOT NULL DEFAULT 0,
        is_draft INTEGER NOT NULL DEFAULT 0,
        is_forwarded INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        keywords TEXT NOT NULL DEFAULT '',
        has_attachments INTEGER NOT NULL DEFAULT 0,
        snippet TEXT NOT NULL DEFAULT '',
        body_state INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account_id, local_id)
      )''',
      'CREATE UNIQUE INDEX d_messages_uid ON d_messages(account_id, folder_id, uid) WHERE uid IS NOT NULL',
      'CREATE INDEX d_messages_list ON d_messages(account_id, folder_id, hidden, sort_ms DESC)',
      'CREATE INDEX d_messages_msgid ON d_messages(account_id, message_id)',
      'CREATE INDEX d_messages_thread ON d_messages(account_id, thread_id)',
      '''
      CREATE TABLE d_bodies (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        body_text TEXT NOT NULL DEFAULT '',
        body_html TEXT,
        has_remote_content INTEGER NOT NULL DEFAULT 0,
        remote_hosts TEXT NOT NULL DEFAULT '[]',
        remote_image_hosts TEXT NOT NULL DEFAULT '[]',
        tracking_hosts TEXT NOT NULL DEFAULT '[]',
        auth_json TEXT,
        security_json TEXT,
        list_unsubscribe TEXT,
        list_unsubscribe_post TEXT,
        receipt_to TEXT,
        PRIMARY KEY (account_id, local_id)
      )''',
      '''
      CREATE TABLE d_parts (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        part_id TEXT NOT NULL,
        content_id TEXT,
        filename TEXT NOT NULL,
        mime TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        is_inline INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account_id, local_id, part_id)
      )''',
    ],
    // 2 — per-account settings (signature, notification choices, …).
    [
      '''
      CREATE TABLE d_settings (
        account_id TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (account_id, key)
      )''',
    ],
    // 3 — where a mail came from before it was trashed or marked as spam
    // (so "restore" can put it back), and when a mail was moved here by this
    // app before the server listed it (so a move that never shows up can be
    // dropped).
    [
      '''
      CREATE TABLE d_origins (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        PRIMARY KEY (account_id, local_id)
      )''',
      'ALTER TABLE d_messages ADD COLUMN moved_ms INTEGER',
    ],
    // 4 — what the app adds on top of the mailbox, which a mail server has no
    // place for: pins, snoozes, labels, contacts, trusted senders, templates,
    // signatures and sending identities. Message-bound rows go with the
    // message.
    [
      '''
      CREATE TABLE d_pins (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        pinned_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, local_id)
      )''',
      '''
      CREATE TABLE d_snoozes (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        until_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, local_id)
      )''',
      '''
      CREATE TABLE d_labels (
        account_id TEXT NOT NULL,
        label_id TEXT NOT NULL,
        name TEXT NOT NULL,
        color INTEGER NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (account_id, label_id)
      )''',
      '''
      CREATE TABLE d_label_assignments (
        account_id TEXT NOT NULL,
        local_id TEXT NOT NULL,
        label_id TEXT NOT NULL,
        PRIMARY KEY (account_id, local_id, label_id)
      )''',
      'CREATE INDEX d_label_assignments_label ON d_label_assignments(account_id, label_id)',
      '''
      CREATE TABLE d_contacts (
        account_id TEXT NOT NULL,
        contact_id TEXT NOT NULL,
        email TEXT NOT NULL,
        display_name TEXT,
        PRIMARY KEY (account_id, contact_id)
      )''',
      '''
      CREATE TABLE d_trusted_senders (
        account_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        value TEXT NOT NULL,
        created_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, sender_id)
      )''',
      '''
      CREATE TABLE d_templates (
        account_id TEXT NOT NULL,
        template_id TEXT NOT NULL,
        name TEXT NOT NULL,
        subject TEXT NOT NULL DEFAULT '',
        body_text TEXT,
        created_ms INTEGER NOT NULL,
        updated_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, template_id)
      )''',
      '''
      CREATE TABLE d_signatures (
        account_id TEXT NOT NULL,
        signature_id TEXT NOT NULL,
        name TEXT NOT NULL,
        body_text TEXT NOT NULL DEFAULT '',
        created_ms INTEGER NOT NULL,
        updated_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, signature_id)
      )''',
      '''
      CREATE TABLE d_identities (
        account_id TEXT NOT NULL,
        identity_id TEXT NOT NULL,
        email TEXT NOT NULL,
        display_name TEXT NOT NULL DEFAULT '',
        reply_to TEXT,
        signature_id TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account_id, identity_id)
      )''',
    ],
  ];

  void _migrate() {
    _db.execute(
      'CREATE TABLE IF NOT EXISTS d_schema (version INTEGER NOT NULL)',
    );
    final rows = _db.select('SELECT version FROM d_schema');
    var current = rows.isEmpty ? 0 : rows.first['version'] as int;
    if (rows.isEmpty) _db.execute('INSERT INTO d_schema VALUES (0)');
    for (var v = current; v < _migrations.length; v++) {
      transaction(() {
        for (final sql in _migrations[v]) {
          _db.execute(sql);
        }
        _db.execute('UPDATE d_schema SET version = ?', [v + 1]);
      });
    }
  }

  static int get latestSchemaVersion => _migrations.length;

  /// Schema version this device is at (for tests).
  int get schemaVersion =>
      _db.select('SELECT version FROM d_schema').first['version'] as int;

  /// Runs [body] atomically. Nested calls join the outer transaction.
  T transaction<T>(T Function() body) {
    if (_depth > 0) return body();
    _db.execute('BEGIN');
    _depth++;
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _depth--;
    }
  }

  int _depth = 0;

  // --- Accounts -------------------------------------------------------------

  void saveAccount(DirectAccountConfig config, {String status = 'active'}) {
    _db.execute(
      '''
      INSERT INTO d_accounts (account_id, email, display_name,
        imap_host, imap_port, imap_security, imap_user,
        smtp_host, smtp_port, smtp_security, smtp_user,
        save_sent_copy, status, created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(account_id) DO UPDATE SET
        display_name = excluded.display_name,
        imap_host = excluded.imap_host, imap_port = excluded.imap_port,
        imap_security = excluded.imap_security, imap_user = excluded.imap_user,
        smtp_host = excluded.smtp_host, smtp_port = excluded.smtp_port,
        smtp_security = excluded.smtp_security, smtp_user = excluded.smtp_user,
        save_sent_copy = excluded.save_sent_copy''',
      [
        config.id,
        config.email,
        config.displayName,
        config.imap.host,
        config.imap.port,
        _securityToText(config.imap.security),
        config.imap.username,
        config.smtp.host,
        config.smtp.port,
        _securityToText(config.smtp.security),
        config.smtp.username,
        config.saveSentCopy ? 1 : 0,
        status,
        now.millisecondsSinceEpoch,
      ],
    );
  }

  DirectAccountConfig? account(String accountId) {
    final rows = _db.select('SELECT * FROM d_accounts WHERE account_id = ?', [
      accountId,
    ]);
    return rows.isEmpty ? null : _accountFrom(rows.first);
  }

  List<DirectAccountConfig> accounts() => [
    for (final row in _db.select(
      'SELECT * FROM d_accounts ORDER BY created_at, account_id',
    ))
      _accountFrom(row),
  ];

  String accountStatus(String accountId) {
    final rows = _db.select(
      'SELECT status FROM d_accounts WHERE account_id = ?',
      [accountId],
    );
    return rows.isEmpty ? 'active' : rows.first['status'] as String;
  }

  void setAccountStatus(String accountId, String status) => _db.execute(
    'UPDATE d_accounts SET status = ? WHERE account_id = ?',
    [status, accountId],
  );

  static String _securityToText(MailSecurity s) =>
      s == MailSecurity.startTls ? 'starttls' : 'tls';

  static DirectAccountConfig _accountFrom(Row row) {
    MailSecurity security(String v) =>
        v == 'starttls' ? MailSecurity.startTls : MailSecurity.sslOnConnect;
    return DirectAccountConfig(
      id: row['account_id'] as String,
      email: row['email'] as String,
      displayName: row['display_name'] as String,
      imap: DirectEndpoint(
        host: row['imap_host'] as String,
        port: row['imap_port'] as int,
        security: security(row['imap_security'] as String),
        username: row['imap_user'] as String,
      ),
      smtp: DirectEndpoint(
        host: row['smtp_host'] as String,
        port: row['smtp_port'] as int,
        security: security(row['smtp_security'] as String),
        username: row['smtp_user'] as String,
      ),
      saveSentCopy: (row['save_sent_copy'] as int) != 0,
    );
  }

  /// Deletes every row of [accountId] from every `d_*` table. Other accounts
  /// are not touched.
  void removeAccount(String accountId) {
    transaction(() {
      final tables = _db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name LIKE 'd\\_%' ESCAPE '\\' AND name <> 'd_schema'",
          )
          .map((row) => row['name'] as String)
          .toList();
      for (final table in tables) {
        _db.execute('DELETE FROM $table WHERE account_id = ?', [accountId]);
      }
    });
  }

  // --- Settings ---------------------------------------------------------------

  String? setting(String accountId, String key) {
    final rows = _db.select(
      'SELECT value FROM d_settings WHERE account_id = ? AND key = ?',
      [accountId, key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Stores [value] under [key]; null removes it.
  void putSetting(String accountId, String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM d_settings WHERE account_id = ? AND key = ?', [
        accountId,
        key,
      ]);
      return;
    }
    _db.execute(
      '''
      INSERT INTO d_settings (account_id, key, value) VALUES (?,?,?)
      ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value''',
      [accountId, key, value],
    );
  }

  // --- Folders ---------------------------------------------------------------

  List<FolderRow> folders(
    String accountId, {
    bool includeUnavailable = false,
  }) => [
    for (final row in _db.select(
      'SELECT * FROM d_folders WHERE account_id = ? '
      '${includeUnavailable ? '' : 'AND available = 1 '}'
      'ORDER BY path',
      [accountId],
    ))
      FolderRow._(row),
  ];

  FolderRow? folder(String accountId, String folderId) {
    final rows = _db.select(
      'SELECT * FROM d_folders WHERE account_id = ? AND folder_id = ?',
      [accountId, folderId],
    );
    return rows.isEmpty ? null : FolderRow._(rows.first);
  }

  FolderRow? folderByPath(String accountId, String path) {
    final rows = _db.select(
      'SELECT * FROM d_folders WHERE account_id = ? AND path = ?',
      [accountId, path],
    );
    return rows.isEmpty ? null : FolderRow._(rows.first);
  }

  /// The available folder playing [role], if any.
  FolderRow? folderByRole(String accountId, FolderRole role) {
    for (final folder in folders(accountId)) {
      if (folder.role == role) return folder;
    }
    return null;
  }

  /// Brings the stored folder list in line with the server's. Folders keep
  /// their ids by path; ones the server no longer lists become unavailable
  /// (their mail is kept until the folder is deleted explicitly), and parent
  /// links are recomputed from the paths.
  ///
  /// [defaultSyncRoles] are switched on for sync the first time a folder is
  /// seen; a later choice by the user is never overwritten.
  void replaceFolders(
    String accountId,
    List<RemoteFolder> remote, {
    Set<FolderRole> defaultSyncRoles = const {
      FolderRole.inbox,
      FolderRole.sent,
    },
  }) {
    transaction(() {
      final existing = {
        for (final f in folders(accountId, includeUnavailable: true)) f.path: f,
      };
      final seen = <String>{};
      for (final folder in remote) {
        seen.add(folder.path);
        final detected = detectRole(folder);
        final previous = existing[folder.path];
        if (previous == null) {
          _db.execute(
            '''
            INSERT INTO d_folders (account_id, folder_id, path, name, delimiter,
              detected_role, attributes, available, sync_enabled)
            VALUES (?,?,?,?,?,?,?,1,?)''',
            [
              accountId,
              newId('f'),
              folder.path,
              folder.name,
              folder.delimiter,
              detected.wireName,
              folder.attributes.join(' '),
              folder.selectable && defaultSyncRoles.contains(detected) ? 1 : 0,
            ],
          );
        } else {
          _db.execute(
            '''
            UPDATE d_folders SET name = ?, delimiter = ?, detected_role = ?,
              attributes = ?, available = 1
            WHERE account_id = ? AND folder_id = ?''',
            [
              folder.name,
              folder.delimiter,
              detected.wireName,
              folder.attributes.join(' '),
              accountId,
              previous.folderId,
            ],
          );
        }
      }
      for (final old in existing.values) {
        if (!seen.contains(old.path) && old.available) {
          _db.execute(
            'UPDATE d_folders SET available = 0 WHERE account_id = ? AND folder_id = ?',
            [accountId, old.folderId],
          );
        }
      }
      _linkParents(accountId);
    });
  }

  void _linkParents(String accountId) {
    final all = folders(accountId);
    final byPath = {for (final f in all) f.path: f.folderId};
    for (final folder in all) {
      final parentPath = folder.delimiter.isEmpty
          ? null
          : folder.path.lastIndexOf(folder.delimiter) <= 0
          ? null
          : folder.path.substring(0, folder.path.lastIndexOf(folder.delimiter));
      final parent = parentPath == null ? null : byPath[parentPath];
      _db.execute(
        'UPDATE d_folders SET parent_folder_id = ? WHERE account_id = ? AND folder_id = ?',
        [parent, accountId, folder.folderId],
      );
    }
  }

  /// The role a folder plays according to the server (SPECIAL-USE) or, when
  /// the server says nothing, its name. Names are matched on the last path
  /// component too (cPanel uses `INBOX.Sent`) and include Turkish ones.
  static FolderRole detectRole(RemoteFolder folder) {
    if (folder.specialUse != null) return folder.specialUse!;
    if (folder.path.toUpperCase() == 'INBOX') return FolderRole.inbox;
    final name = folder.name.toLowerCase().trim();
    bool any(Iterable<String> names) => names.contains(name);
    if (any(const [
      'sent',
      'sent items',
      'sent messages',
      'gönderilmiş öğeler',
      'gönderilenler',
      'giden öğeler',
    ])) {
      return FolderRole.sent;
    }
    if (any(const ['drafts', 'draft', 'taslaklar'])) return FolderRole.drafts;
    if (any(const [
      'trash',
      'deleted items',
      'deleted messages',
      'çöp kutusu',
      'silinmiş öğeler',
      'silinenler',
    ])) {
      return FolderRole.trash;
    }
    if (any(const [
      'junk',
      'spam',
      'junk e-mail',
      'önemsiz',
      'önemsiz e-posta',
      'istenmeyen',
    ])) {
      return FolderRole.junk;
    }
    if (any(const ['archive', 'archives', 'arşiv'])) return FolderRole.archive;
    return FolderRole.custom;
  }

  void setFolderRoleOverride(
    String accountId,
    String folderId,
    FolderRole? role,
  ) => _db.execute(
    'UPDATE d_folders SET role_override = ? WHERE account_id = ? AND folder_id = ?',
    [role?.wireName, accountId, folderId],
  );

  void setFolderSyncEnabled(String accountId, String folderId, bool enabled) =>
      _db.execute(
        'UPDATE d_folders SET sync_enabled = ? WHERE account_id = ? AND folder_id = ?',
        [enabled ? 1 : 0, accountId, folderId],
      );

  /// Marks a folder's older mail as still to be fetched (or as done).
  void setFolderBackfillComplete(
    String accountId,
    String folderId,
    bool complete,
  ) => _db.execute(
    'UPDATE d_folders SET backfill_complete = ? WHERE account_id = ? AND folder_id = ?',
    [complete ? 1 : 0, accountId, folderId],
  );

  /// Stores the UIDVALIDITY the server reports, so rows ingested next carry
  /// it. Does not touch the rest of the sync position.
  void setFolderUidValidity(String accountId, String folderId, int validity) =>
      _db.execute(
        'UPDATE d_folders SET uid_validity = ? WHERE account_id = ? AND folder_id = ?',
        [validity, accountId, folderId],
      );

  /// Records what a successful sync pass learned about a folder.
  void recordFolderSync(
    String accountId,
    String folderId, {
    required int uidValidity,
    required int uidNext,
    required int exists,
    int? unseen,
    int? highestModSeq,
    int? oldestSyncedUid,
    bool? backfillComplete,
  }) {
    _db.execute(
      '''
      UPDATE d_folders SET uid_validity = ?, uid_next = ?, remote_exists = ?,
        remote_unseen = COALESCE(?, remote_unseen),
        highest_modseq = COALESCE(?, highest_modseq),
        oldest_synced_uid = COALESCE(?, oldest_synced_uid),
        backfill_complete = COALESCE(?, backfill_complete),
        last_sync_ms = ?, consecutive_failures = 0,
        last_failure_ms = NULL, last_failure_code = NULL
      WHERE account_id = ? AND folder_id = ?''',
      [
        uidValidity,
        uidNext,
        exists,
        unseen,
        highestModSeq,
        oldestSyncedUid,
        backfillComplete == null ? null : (backfillComplete ? 1 : 0),
        now.millisecondsSinceEpoch,
        accountId,
        folderId,
      ],
    );
  }

  void recordFolderFailure(String accountId, String folderId, String code) =>
      _db.execute(
        '''
        UPDATE d_folders SET last_failure_ms = ?, last_failure_code = ?,
          consecutive_failures = consecutive_failures + 1
        WHERE account_id = ? AND folder_id = ?''',
        [now.millisecondsSinceEpoch, code, accountId, folderId],
      );

  /// Forgets a folder's sync position after the server changed its
  /// UIDVALIDITY: every stored UID is meaningless now.
  void resetFolderSyncPosition(String accountId, String folderId) =>
      _db.execute(
        '''
    UPDATE d_folders SET uid_validity = NULL, uid_next = NULL,
      highest_modseq = NULL, oldest_synced_uid = NULL, backfill_complete = 0
    WHERE account_id = ? AND folder_id = ?''',
        [accountId, folderId],
      );

  // --- Messages ----------------------------------------------------------------

  /// Inserts or updates the message at ([folderId], [uid]). New rows get a
  /// fresh `local_id`; existing ones keep theirs (and with it pins, labels
  /// and snoozes). Returns the `local_id`.
  String upsertMessage(MessageDraft m) {
    final existing = _db.select(
      'SELECT local_id FROM d_messages WHERE account_id = ? AND folder_id = ? AND uid = ?',
      [m.accountId, m.folderId, m.uid],
    );
    final localId = existing.isEmpty
        ? (m.localId ?? newId('d'))
        : existing.first['local_id'] as String;
    _writeMessage(localId, m, insert: existing.isEmpty);
    return localId;
  }

  /// Writes [m] over the stale row [localId] (re-bound after a UIDVALIDITY
  /// reset), keeping the id and every local annotation tied to it.
  void rebindMessage(String localId, MessageDraft m) =>
      _writeMessage(localId, m, insert: false);

  void _writeMessage(String localId, MessageDraft m, {required bool insert}) {
    final values = [
      m.folderId,
      m.uid,
      m.uidValidity,
      m.messageId,
      m.inReplyTo,
      m.references,
      m.threadId,
      m.subject,
      m.fromName,
      m.fromAddress,
      _recipientsToJson(m.to),
      _recipientsToJson(m.cc),
      _recipientsToJson(m.bcc),
      _recipientsToJson(m.replyTo),
      m.sortMs,
      m.dateMs,
      m.internalMs,
      m.size,
      m.isRead ? 1 : 0,
      m.isFlagged ? 1 : 0,
      m.isAnswered ? 1 : 0,
      m.isDraft ? 1 : 0,
      m.isForwarded ? 1 : 0,
      m.isDeleted ? 1 : 0,
      m.keywords.join(' '),
      m.hasAttachments ? 1 : 0,
      m.snippet,
    ];
    if (insert) {
      _db.execute(
        '''
        INSERT INTO d_messages (folder_id, uid, uid_validity, message_id,
          in_reply_to, refs, thread_id, subject, from_name, from_addr,
          to_json, cc_json, bcc_json, reply_to_json, sort_ms, date_ms,
          internal_ms, size, is_read, is_flagged, is_answered, is_draft,
          is_forwarded, is_deleted, keywords, has_attachments, snippet,
          account_id, local_id)
        VALUES (${List.filled(29, '?').join(',')})''',
        [...values, m.accountId, localId],
      );
    } else {
      _db.execute(
        '''
        UPDATE d_messages SET folder_id = ?, uid = ?, uid_validity = ?,
          message_id = ?, in_reply_to = ?, refs = ?, thread_id = ?, subject = ?,
          from_name = ?, from_addr = ?, to_json = ?, cc_json = ?, bcc_json = ?,
          reply_to_json = ?, sort_ms = ?, date_ms = ?, internal_ms = ?,
          size = ?, is_read = ?, is_flagged = ?, is_answered = ?, is_draft = ?,
          is_forwarded = ?, is_deleted = ?, keywords = ?, has_attachments = ?,
          snippet = CASE WHEN ? <> '' THEN ? ELSE snippet END
        WHERE account_id = ? AND local_id = ?''',
        [...values.sublist(0, 26), m.snippet, m.snippet, m.accountId, localId],
      );
    }
  }

  MessageRow? message(String accountId, String localId) {
    final rows = _db.select(
      'SELECT * FROM d_messages WHERE account_id = ? AND local_id = ?',
      [accountId, localId],
    );
    return rows.isEmpty ? null : MessageRow._(rows.first);
  }

  MessageRow? messageByUid(String accountId, String folderId, int uid) {
    final rows = _db.select(
      'SELECT * FROM d_messages WHERE account_id = ? AND folder_id = ? AND uid = ?',
      [accountId, folderId, uid],
    );
    return rows.isEmpty ? null : MessageRow._(rows.first);
  }

  List<MessageRow> messagesByMessageId(String accountId, String messageId) => [
    for (final row in _db.select(
      'SELECT * FROM d_messages WHERE account_id = ? AND message_id = ?',
      [accountId, messageId],
    ))
      MessageRow._(row),
  ];

  /// The `WHERE` tail shared by [page] and [count]: a folder's visible
  /// messages narrowed by the list filters.
  ({String sql, List<Object?> args}) _listFilter(
    String accountId,
    String folderId, {
    bool? unreadOnly,
    bool? flaggedOnly,
    bool? isRead,
    bool? hasAttachments,
    String? text,
  }) {
    final read = unreadOnly == true ? false : isRead;
    final args = <Object?>[accountId, folderId];
    final sql = StringBuffer(
      'account_id = ? AND folder_id = ? AND hidden = 0 AND uid IS NOT NULL',
    );
    if (read != null) sql.write(' AND is_read = ${read ? 1 : 0}');
    if (flaggedOnly == true) sql.write(' AND is_flagged = 1');
    if (hasAttachments != null) {
      sql.write(' AND has_attachments = ${hasAttachments ? 1 : 0}');
    }
    final needle = text?.trim() ?? '';
    if (needle.isNotEmpty) {
      final like = '%${_likeEscape(needle)}%';
      sql.write(
        " AND (subject LIKE ? ESCAPE '\\' OR from_name LIKE ? ESCAPE '\\' "
        "OR from_addr LIKE ? ESCAPE '\\' OR to_json LIKE ? ESCAPE '\\' "
        "OR snippet LIKE ? ESCAPE '\\')",
      );
      args.addAll([like, like, like, like, like]);
    }
    return (sql: sql.toString(), args: args);
  }

  static String _likeEscape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// One page of a folder, newest first, hidden rows left out.
  List<MessageRow> page(
    String accountId,
    String folderId, {
    required int offset,
    required int limit,
    bool? unreadOnly,
    bool? flaggedOnly,
    bool? isRead,
    bool? hasAttachments,
    String? text,
  }) {
    final filter = _listFilter(
      accountId,
      folderId,
      unreadOnly: unreadOnly,
      flaggedOnly: flaggedOnly,
      isRead: isRead,
      hasAttachments: hasAttachments,
      text: text,
    );
    return [
      for (final row in _db.select(
        'SELECT * FROM d_messages WHERE ${filter.sql} '
        'ORDER BY sort_ms DESC, uid DESC LIMIT ? OFFSET ?',
        [...filter.args, limit, offset],
      ))
        MessageRow._(row),
    ];
  }

  int count(
    String accountId,
    String folderId, {
    bool? unreadOnly,
    bool? flaggedOnly,
    bool? isRead,
    bool? hasAttachments,
    String? text,
  }) {
    final filter = _listFilter(
      accountId,
      folderId,
      unreadOnly: unreadOnly,
      flaggedOnly: flaggedOnly,
      isRead: isRead,
      hasAttachments: hasAttachments,
      text: text,
    );
    return _db
            .select(
              'SELECT COUNT(*) AS n FROM d_messages WHERE ${filter.sql}',
              filter.args,
            )
            .first['n']
        as int;
  }

  int unreadCount(String accountId, String folderId) =>
      count(accountId, folderId, unreadOnly: true);

  /// UIDs stored for a folder, ascending.
  List<int> uids(
    String accountId,
    String folderId, {
    int? fromUid,
    int? toUid,
  }) => [
    for (final row in _db.select(
      'SELECT uid FROM d_messages WHERE account_id = ? AND folder_id = ? '
      'AND uid IS NOT NULL AND uid >= ? AND uid <= ? ORDER BY uid',
      [accountId, folderId, fromUid ?? 0, toUid ?? 0x7fffffff],
    ))
      row['uid'] as int,
  ];

  int? minUid(String accountId, String folderId) {
    final v = _db.select(
      'SELECT MIN(uid) AS v FROM d_messages WHERE account_id = ? AND folder_id = ? AND uid IS NOT NULL',
      [accountId, folderId],
    ).first['v'];
    return v as int?;
  }

  int? maxUid(String accountId, String folderId) {
    final v = _db.select(
      'SELECT MAX(uid) AS v FROM d_messages WHERE account_id = ? AND folder_id = ? AND uid IS NOT NULL',
      [accountId, folderId],
    ).first['v'];
    return v as int?;
  }

  /// Flags of the stored messages with UID in range, for diffing.
  Map<int, MessageFlagsRow> flagsByUid(
    String accountId,
    String folderId, {
    int fromUid = 0,
    int? toUid,
  }) => {
    for (final row in _db.select(
      'SELECT uid, local_id, is_read, is_flagged, is_answered, is_draft, '
      'is_forwarded, is_deleted, keywords FROM d_messages '
      'WHERE account_id = ? AND folder_id = ? AND uid IS NOT NULL '
      'AND uid >= ? AND uid <= ?',
      [accountId, folderId, fromUid, toUid ?? 0x7fffffff],
    ))
      row['uid'] as int: MessageFlagsRow._(row),
  };

  void updateFlags(
    String accountId,
    String localId, {
    required bool isRead,
    required bool isFlagged,
    required bool isAnswered,
    required bool isDraft,
    required bool isForwarded,
    required bool isDeleted,
    required List<String> keywords,
  }) => _db.execute(
    '''
    UPDATE d_messages SET is_read = ?, is_flagged = ?, is_answered = ?,
      is_draft = ?, is_forwarded = ?, is_deleted = ?, keywords = ?
    WHERE account_id = ? AND local_id = ?''',
    [
      isRead ? 1 : 0,
      isFlagged ? 1 : 0,
      isAnswered ? 1 : 0,
      isDraft ? 1 : 0,
      isForwarded ? 1 : 0,
      isDeleted ? 1 : 0,
      keywords.join(' '),
      accountId,
      localId,
    ],
  );

  /// Removes messages by UID (gone from the server) together with their
  /// bodies, parts and local annotations.
  void deleteByUids(String accountId, String folderId, Iterable<int> uids) {
    transaction(() {
      for (final uid in uids) {
        final row = messageByUid(accountId, folderId, uid);
        if (row != null) deleteMessage(accountId, row.localId);
      }
    });
  }

  /// Tables that hold rows about one message, keyed by `local_id`; they go
  /// when the message does.
  static const _perMessageTables = [
    'd_bodies',
    'd_parts',
    'd_origins',
    'd_pins',
    'd_snoozes',
    'd_label_assignments',
  ];

  void deleteMessage(String accountId, String localId) {
    for (final table in _perMessageTables) {
      _db.execute('DELETE FROM $table WHERE account_id = ? AND local_id = ?', [
        accountId,
        localId,
      ]);
    }
    _db.execute(
      'DELETE FROM d_messages WHERE account_id = ? AND local_id = ?',
      [accountId, localId],
    );
  }

  /// Moves a stored message to another folder, keeping its id (and with it
  /// every pin, label and snooze). With [uid] the message is bound to its new
  /// place at once; without, it waits there until a sync of that folder lists
  /// it and re-binds it by Message-ID.
  void moveMessage(
    String accountId,
    String localId, {
    required String folderId,
    int? uid,
    int? uidValidity,
  }) {
    transaction(() {
      if (uid != null) {
        final other = messageByUid(accountId, folderId, uid);
        if (other != null && other.localId != localId) {
          deleteMessage(accountId, other.localId);
        }
      }
      _db.execute(
        '''
        UPDATE d_messages SET folder_id = ?, uid = ?, uid_validity = ?,
          moved_ms = ?
        WHERE account_id = ? AND local_id = ?''',
        [
          folderId,
          uid,
          uidValidity,
          uid == null ? now.millisecondsSinceEpoch : null,
          accountId,
          localId,
        ],
      );
    });
  }

  /// Removes messages that were moved into [folderId] before [beforeMs] and
  /// that no sync has listed since: they are not there.
  int dropUnmatchedMoves(
    String accountId,
    String folderId, {
    required int beforeMs,
  }) {
    final rows = _db.select(
      'SELECT local_id FROM d_messages WHERE account_id = ? AND folder_id = ? '
      'AND uid IS NULL AND moved_ms IS NOT NULL AND moved_ms < ?',
      [accountId, folderId, beforeMs],
    );
    transaction(() {
      for (final row in rows) {
        deleteMessage(accountId, row['local_id'] as String);
      }
    });
    return rows.length;
  }

  /// Keeps a folder's remembered server counts right after this app changed
  /// them itself, so lists and badges do not wait for the next sync.
  void adjustFolderCounts(
    String accountId,
    String folderId, {
    int existsDelta = 0,
    int unseenDelta = 0,
    int? uidNext,
  }) => _db.execute(
    '''
    UPDATE d_folders SET
      remote_exists = CASE WHEN remote_exists IS NULL THEN NULL
        ELSE MAX(0, remote_exists + ?) END,
      remote_unseen = CASE WHEN remote_unseen IS NULL THEN NULL
        ELSE MAX(0, remote_unseen + ?) END,
      uid_next = COALESCE(?, uid_next)
    WHERE account_id = ? AND folder_id = ?''',
    [existsDelta, unseenDelta, uidNext, accountId, folderId],
  );

  // --- Origins (restore from Trash / Spam) -------------------------------------

  String? origin(String accountId, String localId) {
    final rows = _db.select(
      'SELECT folder_id FROM d_origins WHERE account_id = ? AND local_id = ?',
      [accountId, localId],
    );
    return rows.isEmpty ? null : rows.first['folder_id'] as String;
  }

  void putOrigin(String accountId, String localId, String? folderId) {
    if (folderId == null) {
      _db.execute(
        'DELETE FROM d_origins WHERE account_id = ? AND local_id = ?',
        [accountId, localId],
      );
      return;
    }
    _db.execute(
      '''
      INSERT INTO d_origins (account_id, local_id, folder_id) VALUES (?,?,?)
      ON CONFLICT(account_id, local_id) DO UPDATE SET folder_id = excluded.folder_id''',
      [accountId, localId, folderId],
    );
  }

  // --- Folder tree changes ------------------------------------------------------------

  /// Gives the folder at [oldPath] and everything below it new paths,
  /// keeping their ids, so the mail stored under them stays attached.
  void renameFolderTree(
    String accountId,
    String oldPath,
    String newPath, {
    required String newName,
  }) {
    transaction(() {
      final all = folders(accountId, includeUnavailable: true);
      for (final folder in all) {
        final String? path;
        if (folder.path == oldPath) {
          path = newPath;
        } else if (folder.delimiter.isNotEmpty &&
            folder.path.startsWith('$oldPath${folder.delimiter}')) {
          path = newPath + folder.path.substring(oldPath.length);
        } else {
          path = null;
        }
        if (path == null) continue;
        _db.execute(
          'UPDATE d_folders SET path = ?, name = ? '
          'WHERE account_id = ? AND folder_id = ?',
          [
            path,
            folder.path == oldPath ? newName : folder.name,
            accountId,
            folder.folderId,
          ],
        );
      }
      _linkParents(accountId);
    });
  }

  /// Forgets a folder the user deleted on the server, with its mail.
  void deleteFolder(String accountId, String folderId) {
    transaction(() {
      for (final row in _db.select(
        'SELECT local_id FROM d_messages WHERE account_id = ? AND folder_id = ?',
        [accountId, folderId],
      )) {
        deleteMessage(accountId, row['local_id'] as String);
      }
      _db.execute(
        'DELETE FROM d_folders WHERE account_id = ? AND folder_id = ?',
        [accountId, folderId],
      );
    });
  }

  /// After a UIDVALIDITY change: detach every message of the folder from its
  /// (now meaningless) UID but keep the row, so a later pass can re-bind it
  /// by Message-ID and the pins, labels and snoozes tied to it survive.
  void markFolderStale(String accountId, String folderId) => _db.execute(
    'UPDATE d_messages SET uid = NULL, uid_validity = NULL '
    'WHERE account_id = ? AND folder_id = ?',
    [accountId, folderId],
  );

  /// Stale rows of a folder that were never re-bound.
  List<MessageRow> staleMessages(String accountId, String folderId) => [
    for (final row in _db.select(
      'SELECT * FROM d_messages WHERE account_id = ? AND folder_id = ? '
      'AND uid IS NULL AND hidden = 0',
      [accountId, folderId],
    ))
      MessageRow._(row),
  ];

  // --- Bodies and parts ------------------------------------------------------------

  BodyRow? body(String accountId, String localId) {
    final rows = _db.select(
      'SELECT * FROM d_bodies WHERE account_id = ? AND local_id = ?',
      [accountId, localId],
    );
    return rows.isEmpty ? null : BodyRow._(rows.first);
  }

  void saveBody(
    String accountId,
    String localId,
    BodyDraft b,
    List<PartDraft> parts,
  ) {
    transaction(() {
      _db.execute(
        '''
        INSERT OR REPLACE INTO d_bodies (account_id, local_id, body_text,
          body_html, has_remote_content, remote_hosts, remote_image_hosts,
          tracking_hosts, auth_json, security_json, list_unsubscribe,
          list_unsubscribe_post, receipt_to)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [
          accountId,
          localId,
          b.text,
          b.html,
          b.hasRemoteContent ? 1 : 0,
          jsonEncode(b.remoteHosts),
          jsonEncode(b.remoteImageHosts),
          jsonEncode(b.trackingHosts),
          b.authJson,
          b.securityJson,
          b.listUnsubscribe,
          b.listUnsubscribePost,
          b.receiptTo,
        ],
      );
      _db.execute('DELETE FROM d_parts WHERE account_id = ? AND local_id = ?', [
        accountId,
        localId,
      ]);
      for (final p in parts) {
        _db.execute(
          '''
          INSERT INTO d_parts (account_id, local_id, part_id, content_id,
            filename, mime, size, is_inline) VALUES (?,?,?,?,?,?,?,?)''',
          [
            accountId,
            localId,
            p.partId,
            p.contentId,
            p.filename,
            p.mime,
            p.size,
            p.isInline ? 1 : 0,
          ],
        );
      }
      _db.execute(
        'UPDATE d_messages SET body_state = 1, has_attachments = ?, '
        'snippet = CASE WHEN ? <> \'\' THEN ? ELSE snippet END '
        'WHERE account_id = ? AND local_id = ?',
        [
          parts.any((p) => !p.isInline) ? 1 : 0,
          b.snippet,
          b.snippet,
          accountId,
          localId,
        ],
      );
    });
  }

  List<PartRow> parts(String accountId, String localId) => [
    for (final row in _db.select(
      'SELECT * FROM d_parts WHERE account_id = ? AND local_id = ? ORDER BY part_id',
      [accountId, localId],
    ))
      PartRow._(row),
  ];

  // --- Threads -----------------------------------------------------------------------

  ThreadRow? thread(String accountId, String threadId) {
    final rows = _db.select(
      'SELECT * FROM d_threads WHERE account_id = ? AND thread_id = ?',
      [accountId, threadId],
    );
    return rows.isEmpty ? null : ThreadRow._(rows.first);
  }

  String createThread(
    String accountId, {
    required String normalizedSubject,
    required int atMs,
  }) {
    final id = newId('c');
    _db.execute(
      'INSERT INTO d_threads (account_id, thread_id, normalized_subject, started_ms, last_ms) '
      'VALUES (?,?,?,?,?)',
      [accountId, id, normalizedSubject, atMs, atMs],
    );
    return id;
  }

  void widenThread(String accountId, String threadId, int atMs) => _db.execute(
    '''
    UPDATE d_threads SET started_ms = MIN(started_ms, ?), last_ms = MAX(last_ms, ?)
    WHERE account_id = ? AND thread_id = ?''',
    [atMs, atMs, accountId, threadId],
  );

  void setThreadSubject(String accountId, String threadId, String subject) =>
      _db.execute(
        'UPDATE d_threads SET normalized_subject = ? WHERE account_id = ? AND thread_id = ?',
        [subject, accountId, threadId],
      );

  /// Moves every message of [losers] into [survivor] and drops the losers.
  void mergeThreads(
    String accountId,
    String survivor,
    Iterable<String> losers,
  ) {
    for (final loser in losers) {
      final row = thread(accountId, loser);
      _db.execute(
        'UPDATE d_messages SET thread_id = ? WHERE account_id = ? AND thread_id = ?',
        [survivor, accountId, loser],
      );
      if (row != null) {
        widenThread(accountId, survivor, row.startedMs);
        widenThread(accountId, survivor, row.lastMs);
      }
      _db.execute(
        'DELETE FROM d_threads WHERE account_id = ? AND thread_id = ?',
        [accountId, loser],
      );
    }
  }

  /// Threads of mail that references or answers [keys] / [messageId].
  List<String> threadsLinkedTo(
    String accountId, {
    required Set<String> keys,
    required String messageId,
    required String exceptLocalId,
  }) {
    final out = <String>{};
    void add(Iterable<Row> rows) {
      for (final r in rows) {
        final t = r['thread_id'] as String;
        if (t.isNotEmpty) out.add(t);
      }
    }

    if (keys.isNotEmpty) {
      final marks = List.filled(keys.length, '?').join(',');
      add(
        _db.select(
          'SELECT DISTINCT thread_id FROM d_messages WHERE account_id = ? '
          'AND local_id <> ? AND message_id IN ($marks)',
          [accountId, exceptLocalId, ...keys],
        ),
      );
    }
    if (messageId.isNotEmpty) {
      add(
        _db.select(
          'SELECT DISTINCT thread_id FROM d_messages WHERE account_id = ? '
          'AND local_id <> ? AND (message_id = ? OR in_reply_to = ?)',
          [accountId, exceptLocalId, messageId, messageId],
        ),
      );
    }
    final ordered = out.toList();
    ordered.sort((a, b) {
      final ta = thread(accountId, a);
      final tb = thread(accountId, b);
      final byStart = (ta?.startedMs ?? 0).compareTo(tb?.startedMs ?? 0);
      return byStart != 0 ? byStart : a.compareTo(b);
    });
    return ordered;
  }

  List<ThreadRow> threadsBySubject(
    String accountId,
    String normalizedSubject, {
    required int fromMs,
    required int toMs,
  }) => [
    for (final row in _db.select(
      'SELECT * FROM d_threads WHERE account_id = ? AND normalized_subject = ? '
      'AND last_ms >= ? AND last_ms <= ? ORDER BY last_ms DESC LIMIT 20',
      [accountId, normalizedSubject, fromMs, toMs],
    ))
      ThreadRow._(row),
  ];

  /// Addresses (lower-case) on any message of [threadId]: sender, To, Cc,
  /// Bcc and Reply-To alike.
  Set<String> threadParticipants(String accountId, String threadId) {
    final out = <String>{};
    for (final row in _db.select(
      'SELECT from_addr, to_json, cc_json, bcc_json, reply_to_json '
      'FROM d_messages WHERE account_id = ? AND thread_id = ?',
      [accountId, threadId],
    )) {
      final from = (row['from_addr'] as String).toLowerCase();
      if (from.isNotEmpty) out.add(from);
      for (final key in const [
        'to_json',
        'cc_json',
        'bcc_json',
        'reply_to_json',
      ]) {
        for (final r in _recipientsFromJson(row[key] as String)) {
          out.add(r.address.toLowerCase());
        }
      }
    }
    return out;
  }

  static const _visibleThread =
      'EXISTS (SELECT 1 FROM d_messages m WHERE m.account_id = t.account_id '
      'AND m.thread_id = t.thread_id AND m.hidden = 0 AND m.uid IS NOT NULL)';

  /// Threads that still have a visible message, newest activity first.
  List<ThreadRow> threads(
    String accountId, {
    required int offset,
    required int limit,
  }) => [
    for (final row in _db.select(
      'SELECT t.* FROM d_threads t WHERE t.account_id = ? AND $_visibleThread '
      'ORDER BY t.last_ms DESC, t.thread_id LIMIT ? OFFSET ?',
      [accountId, limit, offset],
    ))
      ThreadRow._(row),
  ];

  int threadCount(String accountId) =>
      _db.select(
            'SELECT COUNT(*) AS n FROM d_threads t WHERE t.account_id = ? '
            'AND $_visibleThread',
            [accountId],
          ).first['n']
          as int;

  List<MessageRow> threadMessages(String accountId, String threadId) => [
    for (final row in _db.select(
      'SELECT * FROM d_messages WHERE account_id = ? AND thread_id = ? '
      'AND hidden = 0 AND uid IS NOT NULL ORDER BY sort_ms, uid',
      [accountId, threadId],
    ))
      MessageRow._(row),
  ];
}

String _recipientsToJson(List<MailRecipient> list) => jsonEncode([
  for (final r in list) [r.address, r.displayName],
]);

List<MailRecipient> _recipientsFromJson(String json) {
  try {
    return [
      for (final item in jsonDecode(json) as List)
        MailRecipient(
          (item as List)[0] as String,
          item.length > 1 ? item[1] as String : '',
        ),
    ];
  } catch (_) {
    return const [];
  }
}

// --- Row and draft types ------------------------------------------------------------

/// A stored folder.
@immutable
class FolderRow {
  FolderRow._(Row row)
    : accountId = row['account_id'] as String,
      folderId = row['folder_id'] as String,
      path = row['path'] as String,
      name = row['name'] as String,
      delimiter = row['delimiter'] as String,
      parentFolderId = row['parent_folder_id'] as String?,
      detectedRole = FolderRole.fromWireName(row['detected_role'] as String),
      roleOverride = row['role_override'] == null
          ? null
          : FolderRole.fromWireName(row['role_override'] as String),
      attributes = {
        for (final a in (row['attributes'] as String).split(' '))
          if (a.isNotEmpty) a,
      },
      available = (row['available'] as int) != 0,
      syncEnabled = (row['sync_enabled'] as int) != 0,
      uidValidity = row['uid_validity'] as int?,
      uidNext = row['uid_next'] as int?,
      highestModSeq = row['highest_modseq'] as int?,
      remoteExists = row['remote_exists'] as int?,
      remoteUnseen = row['remote_unseen'] as int?,
      oldestSyncedUid = row['oldest_synced_uid'] as int?,
      backfillComplete = (row['backfill_complete'] as int) != 0,
      lastSyncMs = row['last_sync_ms'] as int?,
      lastFailureMs = row['last_failure_ms'] as int?,
      lastFailureCode = row['last_failure_code'] as String?,
      consecutiveFailures = row['consecutive_failures'] as int;

  final String accountId;
  final String folderId;
  final String path;
  final String name;
  final String delimiter;
  final String? parentFolderId;
  final FolderRole detectedRole;
  final FolderRole? roleOverride;
  final Set<String> attributes;
  final bool available;
  final bool syncEnabled;
  final int? uidValidity;
  final int? uidNext;
  final int? highestModSeq;
  final int? remoteExists;
  final int? remoteUnseen;
  final int? oldestSyncedUid;
  final bool backfillComplete;
  final int? lastSyncMs;
  final int? lastFailureMs;
  final String? lastFailureCode;
  final int consecutiveFailures;

  /// The role in effect: the user's choice, else what was detected.
  FolderRole get role => roleOverride ?? detectedRole;

  bool get selectable => !attributes.contains(r'\noselect');
}

/// A stored message header row.
@immutable
class MessageRow {
  MessageRow._(Row row)
    : accountId = row['account_id'] as String,
      localId = row['local_id'] as String,
      folderId = row['folder_id'] as String,
      uid = row['uid'] as int?,
      uidValidity = row['uid_validity'] as int?,
      messageId = row['message_id'] as String,
      inReplyTo = row['in_reply_to'] as String,
      references = row['refs'] as String,
      threadId = row['thread_id'] as String,
      subject = row['subject'] as String,
      fromName = row['from_name'] as String,
      fromAddress = row['from_addr'] as String,
      to = _recipientsFromJson(row['to_json'] as String),
      cc = _recipientsFromJson(row['cc_json'] as String),
      bcc = _recipientsFromJson(row['bcc_json'] as String),
      replyTo = _recipientsFromJson(row['reply_to_json'] as String),
      sortMs = row['sort_ms'] as int,
      dateMs = row['date_ms'] as int,
      internalMs = row['internal_ms'] as int?,
      size = row['size'] as int,
      isRead = (row['is_read'] as int) != 0,
      isFlagged = (row['is_flagged'] as int) != 0,
      isAnswered = (row['is_answered'] as int) != 0,
      isDraft = (row['is_draft'] as int) != 0,
      isForwarded = (row['is_forwarded'] as int) != 0,
      isDeleted = (row['is_deleted'] as int) != 0,
      keywords = [
        for (final k in (row['keywords'] as String).split(' '))
          if (k.isNotEmpty) k,
      ],
      hasAttachments = (row['has_attachments'] as int) != 0,
      snippet = row['snippet'] as String,
      bodyLoaded = (row['body_state'] as int) != 0,
      hidden = (row['hidden'] as int) != 0;

  final String accountId;
  final String localId;
  final String folderId;
  final int? uid;
  final int? uidValidity;
  final String messageId;
  final String inReplyTo;
  final String references;
  final String threadId;
  final String subject;
  final String fromName;
  final String fromAddress;
  final List<MailRecipient> to;
  final List<MailRecipient> cc;
  final List<MailRecipient> bcc;
  final List<MailRecipient> replyTo;
  final int sortMs;
  final int dateMs;
  final int? internalMs;
  final int size;
  final bool isRead;
  final bool isFlagged;
  final bool isAnswered;
  final bool isDraft;
  final bool isForwarded;
  final bool isDeleted;
  final List<String> keywords;
  final bool hasAttachments;
  final String snippet;
  final bool bodyLoaded;
  final bool hidden;
}

@immutable
class MessageFlagsRow {
  MessageFlagsRow._(Row row)
    : localId = row['local_id'] as String,
      isRead = (row['is_read'] as int) != 0,
      isFlagged = (row['is_flagged'] as int) != 0,
      isAnswered = (row['is_answered'] as int) != 0,
      isDraft = (row['is_draft'] as int) != 0,
      isForwarded = (row['is_forwarded'] as int) != 0,
      isDeleted = (row['is_deleted'] as int) != 0,
      keywords = [
        for (final k in (row['keywords'] as String).split(' '))
          if (k.isNotEmpty) k,
      ];

  final String localId;
  final bool isRead;
  final bool isFlagged;
  final bool isAnswered;
  final bool isDraft;
  final bool isForwarded;
  final bool isDeleted;
  final List<String> keywords;
}

/// Everything needed to write a message row.
class MessageDraft {
  MessageDraft({
    required this.accountId,
    required this.folderId,
    required this.uid,
    required this.uidValidity,
    this.localId,
    this.messageId = '',
    this.inReplyTo = '',
    this.references = '',
    this.threadId = '',
    this.subject = '',
    this.fromName = '',
    this.fromAddress = '',
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.replyTo = const [],
    required this.sortMs,
    required this.dateMs,
    this.internalMs,
    this.size = 0,
    this.isRead = false,
    this.isFlagged = false,
    this.isAnswered = false,
    this.isDraft = false,
    this.isForwarded = false,
    this.isDeleted = false,
    this.keywords = const [],
    this.hasAttachments = false,
    this.snippet = '',
  });

  final String accountId;
  final String folderId;
  final int? uid;
  final int? uidValidity;
  final String? localId;
  final String messageId;
  final String inReplyTo;
  final String references;
  final String threadId;
  final String subject;
  final String fromName;
  final String fromAddress;
  final List<MailRecipient> to;
  final List<MailRecipient> cc;
  final List<MailRecipient> bcc;
  final List<MailRecipient> replyTo;
  final int sortMs;
  final int dateMs;
  final int? internalMs;
  final int size;
  final bool isRead;
  final bool isFlagged;
  final bool isAnswered;
  final bool isDraft;
  final bool isForwarded;
  final bool isDeleted;
  final List<String> keywords;
  final bool hasAttachments;
  final String snippet;
}

@immutable
class BodyRow {
  BodyRow._(Row row)
    : text = row['body_text'] as String,
      html = row['body_html'] as String?,
      hasRemoteContent = (row['has_remote_content'] as int) != 0,
      remoteHosts = _stringList(row['remote_hosts'] as String),
      remoteImageHosts = _stringList(row['remote_image_hosts'] as String),
      trackingHosts = _stringList(row['tracking_hosts'] as String),
      authJson = row['auth_json'] as String?,
      securityJson = row['security_json'] as String?,
      listUnsubscribe = row['list_unsubscribe'] as String?,
      listUnsubscribePost = row['list_unsubscribe_post'] as String?,
      receiptTo = row['receipt_to'] as String?;

  final String text;
  final String? html;
  final bool hasRemoteContent;
  final List<String> remoteHosts;
  final List<String> remoteImageHosts;
  final List<String> trackingHosts;
  final String? authJson;
  final String? securityJson;
  final String? listUnsubscribe;
  final String? listUnsubscribePost;
  final String? receiptTo;

  static List<String> _stringList(String json) {
    try {
      return (jsonDecode(json) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }
}

class BodyDraft {
  const BodyDraft({
    required this.text,
    this.html,
    this.hasRemoteContent = false,
    this.remoteHosts = const [],
    this.remoteImageHosts = const [],
    this.trackingHosts = const [],
    this.authJson,
    this.securityJson,
    this.listUnsubscribe,
    this.listUnsubscribePost,
    this.receiptTo,
    this.snippet = '',
  });

  final String text;
  final String? html;
  final bool hasRemoteContent;
  final List<String> remoteHosts;
  final List<String> remoteImageHosts;
  final List<String> trackingHosts;
  final String? authJson;
  final String? securityJson;
  final String? listUnsubscribe;
  final String? listUnsubscribePost;
  final String? receiptTo;
  final String snippet;
}

class PartDraft {
  const PartDraft({
    required this.partId,
    required this.filename,
    required this.mime,
    required this.size,
    this.contentId,
    this.isInline = false,
  });

  final String partId;
  final String filename;
  final String mime;
  final int size;
  final String? contentId;
  final bool isInline;
}

@immutable
class PartRow {
  PartRow._(Row row)
    : partId = row['part_id'] as String,
      contentId = row['content_id'] as String?,
      filename = row['filename'] as String,
      mime = row['mime'] as String,
      size = row['size'] as int,
      isInline = (row['is_inline'] as int) != 0;

  final String partId;
  final String? contentId;
  final String filename;
  final String mime;
  final int size;
  final bool isInline;
}

@immutable
class ThreadRow {
  ThreadRow._(Row row)
    : threadId = row['thread_id'] as String,
      normalizedSubject = row['normalized_subject'] as String,
      startedMs = row['started_ms'] as int,
      lastMs = row['last_ms'] as int;

  final String threadId;
  final String normalizedSubject;
  final int startedMs;
  final int lastMs;
}
