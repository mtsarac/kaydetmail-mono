import 'package:sqlite3/common.dart';

import '../api_exception.dart';
import 'direct_store.dart';

/// A label as stored.
class LabelRow {
  const LabelRow(this.id, this.name, this.color);
  final String id;
  final String name;

  /// Signed ARGB, the form the backend sends.
  final int color;
}

class ContactRow {
  const ContactRow(this.id, this.email, this.displayName);
  final String id;
  final String email;
  final String? displayName;
}

class TrustedRow {
  const TrustedRow(this.id, this.kind, this.value, this.createdMs);
  final String id;

  /// `Sender` or `Domain`.
  final String kind;
  final String value;
  final int createdMs;
}

class TemplateRow {
  const TemplateRow(
    this.id,
    this.name,
    this.subject,
    this.bodyText,
    this.createdMs,
    this.updatedMs,
  );
  final String id;
  final String name;
  final String subject;
  final String? bodyText;
  final int createdMs;
  final int updatedMs;
}

class SignatureRow {
  const SignatureRow(
    this.id,
    this.name,
    this.bodyText,
    this.createdMs,
    this.updatedMs,
  );
  final String id;
  final String name;
  final String bodyText;
  final int createdMs;
  final int updatedMs;
}

class IdentityRow {
  const IdentityRow(
    this.id,
    this.email,
    this.displayName,
    this.replyTo,
    this.signatureId,
    this.isDefault,
  );
  final String id;
  final String email;
  final String displayName;
  final String? replyTo;
  final String? signatureId;
  final bool isDefault;
}

/// The part of the local store that holds what this app adds on top of the
/// mailbox. Failures use the same codes the backend answers with, so the
/// repository's handling of name clashes and limits works unchanged.
class DirectMetaStore {
  DirectMetaStore(this._store);

  final DirectStore _store;

  CommonDatabase get _db => _store.db;

  /// The most mails an account may pin.
  static const maxPinned = 3;

  static ApiException _error(int status, String code) =>
      ApiException(status: status, code: code);

  bool _messageExists(String accountId, String localId) => _db.select(
    'SELECT 1 FROM d_messages WHERE account_id = ? AND local_id = ?',
    [accountId, localId],
  ).isNotEmpty;

  // --- Pins ----------------------------------------------------------------------------

  List<String> pinned(String accountId) => [
    for (final row in _db.select(
      '''
      SELECT p.local_id FROM d_pins p
      JOIN d_messages m ON m.account_id = p.account_id AND m.local_id = p.local_id
      WHERE p.account_id = ? ORDER BY p.pinned_ms, p.local_id''',
      [accountId],
    ))
      row['local_id'] as String,
  ];

  /// Pins [localId]; false when the limit is reached.
  bool pin(String accountId, String localId) {
    final current = pinned(accountId);
    if (current.contains(localId)) return true;
    if (current.length >= maxPinned) return false;
    _db.execute('INSERT INTO d_pins VALUES (?,?,?)', [
      accountId,
      localId,
      _store.now.millisecondsSinceEpoch,
    ]);
    return true;
  }

  void unpin(String accountId, String localId) => _db.execute(
    'DELETE FROM d_pins WHERE account_id = ? AND local_id = ?',
    [accountId, localId],
  );

  // --- Snoozes -------------------------------------------------------------------------

  void snooze(String accountId, String localId, DateTime untilUtc) {
    if (!_messageExists(accountId, localId)) {
      throw _error(404, 'mail_not_found');
    }
    _db.execute(
      '''
      INSERT INTO d_snoozes (account_id, local_id, until_ms) VALUES (?,?,?)
      ON CONFLICT(account_id, local_id) DO UPDATE SET until_ms = excluded.until_ms''',
      [accountId, localId, untilUtc.toUtc().millisecondsSinceEpoch],
    );
  }

  void unsnooze(String accountId, String localId) => _db.execute(
    'DELETE FROM d_snoozes WHERE account_id = ? AND local_id = ?',
    [accountId, localId],
  );

  /// Mail still snoozed; deadlines that passed are dropped on the way.
  Map<String, DateTime> snoozed(String accountId) {
    final nowMs = _store.now.millisecondsSinceEpoch;
    _db.execute(
      'DELETE FROM d_snoozes WHERE account_id = ? AND until_ms <= ?',
      [accountId, nowMs],
    );
    return {
      for (final row in _db.select(
        'SELECT local_id, until_ms FROM d_snoozes WHERE account_id = ?',
        [accountId],
      ))
        row['local_id'] as String: DateTime.fromMillisecondsSinceEpoch(
          row['until_ms'] as int,
          isUtc: true,
        ),
    };
  }

  // --- Labels ----------------------------------------------------------------------------

  List<LabelRow> labels(String accountId) => [
    for (final row in _db.select(
      'SELECT * FROM d_labels WHERE account_id = ? ORDER BY position, name',
      [accountId],
    ))
      LabelRow(
        row['label_id'] as String,
        row['name'] as String,
        row['color'] as int,
      ),
  ];

  bool _labelNameTaken(String accountId, String name, {String? except}) =>
      labels(accountId).any(
        (l) => l.id != except && l.name.toLowerCase() == name.toLowerCase(),
      );

  LabelRow createLabel(String accountId, String name, int color) {
    final clean = name.trim();
    if (clean.isEmpty) throw _error(400, 'invalid_request');
    if (_labelNameTaken(accountId, clean)) {
      throw _error(409, 'label_name_taken');
    }
    final id = _store.newId('l');
    final position =
        (_db.select(
              'SELECT MAX(position) AS p FROM d_labels WHERE account_id = ?',
              [accountId],
            ).first['p']
            as int?) ??
        -1;
    _db.execute('INSERT INTO d_labels VALUES (?,?,?,?,?)', [
      accountId,
      id,
      clean,
      color,
      position + 1,
    ]);
    return LabelRow(id, clean, color);
  }

  LabelRow updateLabel(String accountId, String id, String name, int color) {
    if (!labels(accountId).any((l) => l.id == id)) {
      throw _error(404, 'label_not_found');
    }
    final clean = name.trim();
    if (clean.isEmpty) throw _error(400, 'invalid_request');
    if (_labelNameTaken(accountId, clean, except: id)) {
      throw _error(409, 'label_name_taken');
    }
    _db.execute(
      'UPDATE d_labels SET name = ?, color = ? WHERE account_id = ? AND label_id = ?',
      [clean, color, accountId, id],
    );
    return LabelRow(id, clean, color);
  }

  void deleteLabel(String accountId, String id) {
    _store.transaction(() {
      _db.execute(
        'DELETE FROM d_label_assignments WHERE account_id = ? AND label_id = ?',
        [accountId, id],
      );
      _db.execute(
        'DELETE FROM d_labels WHERE account_id = ? AND label_id = ?',
        [accountId, id],
      );
    });
  }

  Map<String, List<String>> labelAssignments(String accountId) {
    final out = <String, List<String>>{};
    for (final row in _db.select(
      '''
      SELECT a.local_id, a.label_id FROM d_label_assignments a
      JOIN d_messages m ON m.account_id = a.account_id AND m.local_id = a.local_id
      JOIN d_labels l ON l.account_id = a.account_id AND l.label_id = a.label_id
      WHERE a.account_id = ? ORDER BY l.position''',
      [accountId],
    )) {
      out
          .putIfAbsent(row['local_id'] as String, () => [])
          .add(row['label_id'] as String);
    }
    return out;
  }

  void assignLabels(
    String accountId,
    List<String> localIds,
    List<String> labelIds,
  ) {
    final known = {for (final l in labels(accountId)) l.id};
    if (labelIds.any((id) => !known.contains(id))) {
      throw _error(404, 'label_not_found');
    }
    _store.transaction(() {
      for (final localId in localIds) {
        if (!_messageExists(accountId, localId)) continue;
        for (final labelId in labelIds) {
          _db.execute(
            'INSERT OR IGNORE INTO d_label_assignments VALUES (?,?,?)',
            [accountId, localId, labelId],
          );
        }
      }
    });
  }

  void unassignLabels(
    String accountId,
    List<String> localIds,
    List<String> labelIds,
  ) {
    _store.transaction(() {
      for (final localId in localIds) {
        for (final labelId in labelIds) {
          _db.execute(
            'DELETE FROM d_label_assignments '
            'WHERE account_id = ? AND local_id = ? AND label_id = ?',
            [accountId, localId, labelId],
          );
        }
      }
    });
  }

  // --- Contacts -----------------------------------------------------------------------------

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  List<ContactRow> contacts(String accountId) => [
    for (final row in _db.select(
      'SELECT * FROM d_contacts WHERE account_id = ? ORDER BY email',
      [accountId],
    ))
      ContactRow(
        row['contact_id'] as String,
        row['email'] as String,
        row['display_name'] as String?,
      ),
  ];

  bool _contactTaken(String accountId, String email, {String? except}) =>
      contacts(accountId).any(
        (c) => c.id != except && c.email.toLowerCase() == email.toLowerCase(),
      );

  ContactRow createContact(
    String accountId,
    String email,
    String? displayName,
  ) {
    final address = email.trim();
    if (!_emailPattern.hasMatch(address)) throw _error(400, 'invalid_email');
    if (_contactTaken(accountId, address)) {
      throw _error(409, 'contact_already_exists');
    }
    final id = _store.newId('c');
    final name = displayName?.trim();
    _db.execute('INSERT INTO d_contacts VALUES (?,?,?,?)', [
      accountId,
      id,
      address,
      name == null || name.isEmpty ? null : name,
    ]);
    return ContactRow(id, address, name == null || name.isEmpty ? null : name);
  }

  ContactRow updateContact(
    String accountId,
    String id,
    String email,
    String? displayName,
  ) {
    if (!contacts(accountId).any((c) => c.id == id)) {
      throw _error(404, 'contact_not_found');
    }
    final address = email.trim();
    if (!_emailPattern.hasMatch(address)) throw _error(400, 'invalid_email');
    if (_contactTaken(accountId, address, except: id)) {
      throw _error(409, 'contact_already_exists');
    }
    final name = displayName?.trim();
    final stored = name == null || name.isEmpty ? null : name;
    _db.execute(
      'UPDATE d_contacts SET email = ?, display_name = ? '
      'WHERE account_id = ? AND contact_id = ?',
      [address, stored, accountId, id],
    );
    return ContactRow(id, address, stored);
  }

  void deleteContact(String accountId, String id) => _db.execute(
    'DELETE FROM d_contacts WHERE account_id = ? AND contact_id = ?',
    [accountId, id],
  );

  // --- Trusted senders ---------------------------------------------------------------

  List<TrustedRow> trustedSenders(String accountId) => [
    for (final row in _db.select(
      'SELECT * FROM d_trusted_senders WHERE account_id = ? ORDER BY created_ms',
      [accountId],
    ))
      TrustedRow(
        row['sender_id'] as String,
        row['kind'] as String,
        row['value'] as String,
        row['created_ms'] as int,
      ),
  ];

  /// Adding the same sender or domain twice returns the existing entry.
  TrustedRow addTrustedSender(String accountId, String kind, String value) {
    final clean = value.trim().toLowerCase();
    final isDomain = kind == 'Domain';
    final valid = isDomain
        ? clean.isNotEmpty && !clean.contains('@') && clean.contains('.')
        : _emailPattern.hasMatch(clean);
    if (!valid) throw _error(400, 'invalid_request');
    for (final existing in trustedSenders(accountId)) {
      if (existing.kind == kind && existing.value == clean) return existing;
    }
    final id = _store.newId('t');
    final nowMs = _store.now.millisecondsSinceEpoch;
    _db.execute('INSERT INTO d_trusted_senders VALUES (?,?,?,?,?)', [
      accountId,
      id,
      kind,
      clean,
      nowMs,
    ]);
    return TrustedRow(id, kind, clean, nowMs);
  }

  void removeTrustedSender(String accountId, String id) => _db.execute(
    'DELETE FROM d_trusted_senders WHERE account_id = ? AND sender_id = ?',
    [accountId, id],
  );

  /// Whether remote images of mail from [address] are allowed by the user's
  /// trusted list (the sender, or its domain).
  bool isTrusted(String accountId, String address) {
    final lower = address.trim().toLowerCase();
    final at = lower.lastIndexOf('@');
    if (at <= 0) return false;
    final domain = lower.substring(at + 1);
    return trustedSenders(accountId)
        .any((t) => t.kind == 'Domain' ? t.value == domain : t.value == lower);
  }

  // --- Templates ------------------------------------------------------------------------------

  TemplateRow _template(Row row) => TemplateRow(
    row['template_id'] as String,
    row['name'] as String,
    row['subject'] as String,
    row['body_text'] as String?,
    row['created_ms'] as int,
    row['updated_ms'] as int,
  );

  List<TemplateRow> templates(String accountId) => [
    for (final row in _db.select(
      'SELECT * FROM d_templates WHERE account_id = ? ORDER BY name COLLATE NOCASE',
      [accountId],
    ))
      _template(row),
  ];

  bool _templateNameTaken(String accountId, String name, {String? except}) =>
      templates(accountId).any(
        (t) => t.id != except && t.name.toLowerCase() == name.toLowerCase(),
      );

  TemplateRow createTemplate(
    String accountId, {
    required String name,
    required String subject,
    String? bodyText,
  }) {
    final clean = name.trim();
    if (clean.isEmpty) throw _error(400, 'invalid_request');
    if (_templateNameTaken(accountId, clean)) {
      throw _error(409, 'template_name_taken');
    }
    final id = _store.newId('p');
    final nowMs = _store.now.millisecondsSinceEpoch;
    _db.execute('INSERT INTO d_templates VALUES (?,?,?,?,?,?,?)', [
      accountId,
      id,
      clean,
      subject,
      bodyText,
      nowMs,
      nowMs,
    ]);
    return TemplateRow(id, clean, subject, bodyText, nowMs, nowMs);
  }

  TemplateRow updateTemplate(
    String accountId,
    String id, {
    required String name,
    required String subject,
    String? bodyText,
  }) {
    final existing = templates(accountId).where((t) => t.id == id).firstOrNull;
    if (existing == null) throw _error(404, 'template_not_found');
    final clean = name.trim();
    if (clean.isEmpty) throw _error(400, 'invalid_request');
    if (_templateNameTaken(accountId, clean, except: id)) {
      throw _error(409, 'template_name_taken');
    }
    final nowMs = _store.now.millisecondsSinceEpoch;
    _db.execute(
      '''
      UPDATE d_templates SET name = ?, subject = ?, body_text = ?, updated_ms = ?
      WHERE account_id = ? AND template_id = ?''',
      [clean, subject, bodyText, nowMs, accountId, id],
    );
    return TemplateRow(id, clean, subject, bodyText, existing.createdMs, nowMs);
  }

  void deleteTemplate(String accountId, String id) => _db.execute(
    'DELETE FROM d_templates WHERE account_id = ? AND template_id = ?',
    [accountId, id],
  );

  // --- Signatures -------------------------------------------------------------------------------

  SignatureRow _signature(Row row) => SignatureRow(
    row['signature_id'] as String,
    row['name'] as String,
    row['body_text'] as String,
    row['created_ms'] as int,
    row['updated_ms'] as int,
  );

  List<SignatureRow> signatures(String accountId) => [
    for (final row in _db.select(
      'SELECT * FROM d_signatures WHERE account_id = ? ORDER BY name COLLATE NOCASE',
      [accountId],
    ))
      _signature(row),
  ];

  SignatureRow createSignature(
    String accountId, {
    required String name,
    required String bodyText,
  }) {
    final id = _store.newId('s');
    final nowMs = _store.now.millisecondsSinceEpoch;
    _db.execute('INSERT INTO d_signatures VALUES (?,?,?,?,?,?)', [
      accountId,
      id,
      name.trim(),
      bodyText,
      nowMs,
      nowMs,
    ]);
    return SignatureRow(id, name.trim(), bodyText, nowMs, nowMs);
  }

  SignatureRow updateSignature(
    String accountId,
    String id, {
    required String name,
    required String bodyText,
  }) {
    final existing = signatures(accountId).where((s) => s.id == id).firstOrNull;
    if (existing == null) throw _error(404, 'signature_not_found');
    final nowMs = _store.now.millisecondsSinceEpoch;
    _db.execute(
      '''
      UPDATE d_signatures SET name = ?, body_text = ?, updated_ms = ?
      WHERE account_id = ? AND signature_id = ?''',
      [name.trim(), bodyText, nowMs, accountId, id],
    );
    return SignatureRow(id, name.trim(), bodyText, existing.createdMs, nowMs);
  }

  /// Deletes a signature; defaults and identities that named it forget it.
  void deleteSignature(String accountId, String id) {
    _store.transaction(() {
      _db.execute(
        'DELETE FROM d_signatures WHERE account_id = ? AND signature_id = ?',
        [accountId, id],
      );
      _db.execute(
        'UPDATE d_identities SET signature_id = NULL '
        'WHERE account_id = ? AND signature_id = ?',
        [accountId, id],
      );
    });
  }

  // --- Identities --------------------------------------------------------------------------------

  IdentityRow _identity(Row row) => IdentityRow(
    row['identity_id'] as String,
    row['email'] as String,
    row['display_name'] as String,
    row['reply_to'] as String?,
    row['signature_id'] as String?,
    (row['is_default'] as int) != 0,
  );

  List<IdentityRow> identities(String accountId) => [
    for (final row in _db.select(
      'SELECT * FROM d_identities WHERE account_id = ? ORDER BY is_default DESC, email',
      [accountId],
    ))
      _identity(row),
  ];

  IdentityRow createIdentity(
    String accountId, {
    required String email,
    required String displayName,
    String? replyTo,
    String? signatureId,
    required bool isDefault,
  }) {
    final address = email.trim();
    if (!_emailPattern.hasMatch(address)) throw _error(400, 'invalid_email');
    if (identities(accountId)
        .any((i) => i.email.toLowerCase() == address.toLowerCase())) {
      throw _error(409, 'identity_already_exists');
    }
    _requireSignature(accountId, signatureId);
    final id = _store.newId('i');
    _store.transaction(() {
      if (isDefault) _clearDefault(accountId);
      _db.execute('INSERT INTO d_identities VALUES (?,?,?,?,?,?,?)', [
        accountId,
        id,
        address,
        displayName.trim(),
        _blankToNull(replyTo),
        signatureId,
        isDefault ? 1 : 0,
      ]);
    });
    return identities(accountId).firstWhere((i) => i.id == id);
  }

  IdentityRow updateIdentity(
    String accountId,
    String id, {
    required String email,
    required String displayName,
    String? replyTo,
    String? signatureId,
    required bool isDefault,
  }) {
    if (!identities(accountId).any((i) => i.id == id)) {
      throw _error(404, 'identity_not_found');
    }
    final address = email.trim();
    if (!_emailPattern.hasMatch(address)) throw _error(400, 'invalid_email');
    if (identities(accountId).any(
      (i) => i.id != id && i.email.toLowerCase() == address.toLowerCase(),
    )) {
      throw _error(409, 'identity_already_exists');
    }
    _requireSignature(accountId, signatureId);
    _store.transaction(() {
      if (isDefault) _clearDefault(accountId);
      _db.execute(
        '''
        UPDATE d_identities SET email = ?, display_name = ?, reply_to = ?,
          signature_id = ?, is_default = ?
        WHERE account_id = ? AND identity_id = ?''',
        [
          address,
          displayName.trim(),
          _blankToNull(replyTo),
          signatureId,
          isDefault ? 1 : 0,
          accountId,
          id,
        ],
      );
    });
    return identities(accountId).firstWhere((i) => i.id == id);
  }

  void deleteIdentity(String accountId, String id) => _db.execute(
    'DELETE FROM d_identities WHERE account_id = ? AND identity_id = ?',
    [accountId, id],
  );

  void _clearDefault(String accountId) => _db.execute(
    'UPDATE d_identities SET is_default = 0 WHERE account_id = ?',
    [accountId],
  );

  void _requireSignature(String accountId, String? signatureId) {
    if (signatureId != null &&
        !signatures(accountId).any((s) => s.id == signatureId)) {
      throw _error(404, 'signature_not_found');
    }
  }

  static String? _blankToNull(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
