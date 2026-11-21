import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One direct (IMAP/SMTP) account remembered for session restore.
class DirectSessionEntry {
  const DirectSessionEntry({required this.id, required this.email});

  /// Device-generated account id; also the key of its stored credentials and
  /// of every local-store row.
  final String id;
  final String email;
}

/// Persists accounts logged in, in connection order, so [restoreSession]
/// knows what to restore at app launch and auth gate knows login state.
///
/// Backend accounts keep their original keys untouched. Direct accounts live
/// in a registry of their own, so a build that predates direct mode (or a
/// rollback to one) still reads a valid backend-only list. [loadEmails]
/// merges both, which is all the auth gate needs.
class SessionStore {
  SessionStore._();

  static const String _key = 'kaydet.session.emails';
  static const String _accountIdsKey = 'kaydet.session.accountIds';
  static const String _directKey = 'kaydet.session.direct';

  // Pre-multi-account key, migrated into list below first time emails read.
  static const String _legacyKey = 'kaydet.session.email';

  static Future<void> _migrateLegacy(SharedPreferences prefs) async {
    final legacy = prefs.getString(_legacyKey);
    if (legacy == null || legacy.trim().isEmpty) return;
    await prefs.remove(_legacyKey);
    final existing = prefs.getStringList(_key) ?? const <String>[];
    if (!existing.contains(legacy)) {
      await prefs.setStringList(_key, [...existing, legacy]);
    }
  }

  /// Every account email: backend accounts in connection order, then direct
  /// accounts in connection order.
  static Future<List<String>> loadEmails() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacy(prefs);
      final backend = prefs.getStringList(_key) ?? const <String>[];
      return [
        ...backend,
        for (final entry in _loadDirect(prefs))
          if (!backend.contains(entry.email)) entry.email,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [email] belongs to a direct account.
  static Future<DirectSessionEntry?> loadDirectAccount(String email) async {
    try {
      final entries = _loadDirect(await SharedPreferences.getInstance());
      return entries.where((entry) => entry.email == email).firstOrNull;
    } catch (_) {
      return null;
    }
  }

  static Future<List<DirectSessionEntry>> loadDirectAccounts() async {
    try {
      return _loadDirect(await SharedPreferences.getInstance());
    } catch (_) {
      return const [];
    }
  }

  /// Remembers a direct account; re-saving the same id is a no-op.
  static Future<void> saveDirectAccount(String id, String email) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _loadDirect(prefs);
    if (entries.any((entry) => entry.id == id)) return;
    await _saveDirect(prefs, [
      ...entries,
      DirectSessionEntry(id: id, email: email),
    ]);
  }

  static List<DirectSessionEntry> _loadDirect(SharedPreferences prefs) {
    final raw = prefs.getString(_directKey);
    if (raw == null) return const [];
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          DirectSessionEntry(
            id: (item as Map)['id'] as String,
            email: item['email'] as String,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveDirect(
    SharedPreferences prefs,
    List<DirectSessionEntry> entries,
  ) => prefs.setString(
    _directKey,
    jsonEncode([
      for (final entry in entries) {'id': entry.id, 'email': entry.email},
    ]),
  );

  /// Remembers one more logged-in account without duplicate.
  static Future<void> addEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_key) ?? const <String>[];
    if (!existing.contains(email)) {
      await prefs.setStringList(_key, [...existing, email]);
    }
  }

  /// Associates [email] with stable backend [accountId] for session restore.
  static Future<void> saveAccountId(String email, String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final accountIds = _loadAccountIds(prefs)..[email] = accountId;
    await prefs.setString(_accountIdsKey, jsonEncode(accountIds));
  }

  static Future<String?> loadAccountId(String email) async {
    try {
      return _loadAccountIds(await SharedPreferences.getInstance())[email];
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _loadAccountIds(SharedPreferences prefs) {
    final raw = prefs.getString(_accountIdsKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (email, accountId) => MapEntry(email, accountId as String),
      );
    } catch (_) {
      return {};
    }
  }

  /// Forgets one account without touching others.
  static Future<void> removeEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = (prefs.getStringList(_key) ?? const <String>[]).toList()
      ..remove(email);
    final accountIds = _loadAccountIds(prefs)..remove(email);
    final direct = [
      for (final entry in _loadDirect(prefs))
        if (entry.email != email) entry,
    ];
    await Future.wait([
      prefs.setStringList(_key, existing),
      prefs.setString(_accountIdsKey, jsonEncode(accountIds)),
      _saveDirect(prefs, direct),
    ]);
  }

  /// Forgets every logged-in account.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.remove(_key),
        prefs.remove(_accountIdsKey),
        prefs.remove(_directKey),
        prefs.remove(_legacyKey),
      ]);
    } catch (_) {
      // No session to clear in tests / unsupported platforms.
    }
  }

  /// Synchronous test helper: wipes mock prefs.
  static void resetForTest() {
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
    } catch (_) {
      // Not in test environment.
    }
  }
}
