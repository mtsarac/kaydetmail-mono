import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../token_store.dart';

/// The passwords of one direct account.
class DirectCredentials {
  const DirectCredentials({required this.imapPassword, this.smtpPassword});

  final String imapPassword;

  /// Null means the outgoing server uses the same password.
  final String? smtpPassword;

  String get effectiveSmtpPassword => smtpPassword ?? imapPassword;
}

/// Passwords of direct accounts, one record per account id, in the platform
/// keystore. Never in preferences or in the SQLite database.
///
/// iOS keeps them readable after the first unlock of the device (not only
/// while it is unlocked) so a background mailbox check can still sign in,
/// and never lets them leave the device in a backup.
class DirectCredentialStore {
  DirectCredentialStore({TokenStorage? storage})
    : _storage =
          storage ??
          SecureTokenStorage(
            storage: const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            ),
          );

  final TokenStorage _storage;

  static String _key(String accountId) =>
      'kaydet.direct.$accountId.credentials';

  Future<void> save(String accountId, DirectCredentials credentials) =>
      _storage.write(
        _key(accountId),
        jsonEncode({
          'imap': credentials.imapPassword,
          'smtp': credentials.smtpPassword,
        }),
      );

  Future<DirectCredentials?> read(String accountId) async {
    final raw = await _storage.read(_key(accountId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return DirectCredentials(
        imapPassword: json['imap'] as String,
        smtpPassword: json['smtp'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String accountId) => _storage.delete(_key(accountId));
}
