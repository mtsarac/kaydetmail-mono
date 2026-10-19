import 'connection_policy.dart';
import 'direct_account_setup.dart';
import 'direct_connection.dart';
import 'direct_credential_store.dart';
import 'imap_service.dart';

/// Builds the IMAP client of one account; tests supply an in-memory one.
typedef ImapFactory = ImapService Function(
  DirectEndpoint endpoint,
  String password,
);

/// Everything one signed-in direct account needs while the app runs: its
/// settings, its passwords (held in memory only for as long as the account
/// is open) and its single mail-server connection.
///
/// Changing the password or the server settings ([update]) swaps the
/// credentials under the same [connection], so queued work carries on with
/// the new ones and the refused-sign-in lock is lifted exactly once.
class DirectAccountRuntime {
  DirectAccountRuntime({
    required this.config,
    required this.credentials,
    required this._imapFactory,
    this.credentialStore,
    Future<bool> Function()? isOnline,
    ConnectionPolicy? policy,
    Duration idleClose = const Duration(seconds: 60),
  }) {
    connection = DirectConnection(
      create: () => _imapFactory(config.imap, credentials.imapPassword),
      policy: policy,
      isOnline: isOnline,
      idleClose: idleClose,
      onNeedsReauthentication: () => onNeedsReauthentication?.call(),
      onRecovered: () => onRecovered?.call(),
    );
  }

  DirectAccountConfig config;
  DirectCredentials credentials;
  final ImapFactory _imapFactory;

  /// Where the passwords are kept between launches; null in tests.
  final DirectCredentialStore? credentialStore;
  late final DirectConnection connection;

  /// Called by the owner when the account is deleted, after its mail is gone.
  Future<void> Function()? onDeleted;

  /// Called once when the server refuses the stored credentials.
  void Function()? onNeedsReauthentication;

  /// Called when the account signs in again after that.
  void Function()? onRecovered;

  String get accountId => config.id;

  /// Replaces the settings and passwords after the user corrected them.
  Future<void> update({
    required DirectAccountConfig config,
    required DirectCredentials credentials,
  }) async {
    this.config = config;
    this.credentials = credentials;
    await connection.credentialsChanged();
  }

  /// Writes the current passwords to the keystore.
  Future<void> persistCredentials() async =>
      credentialStore?.save(accountId, credentials);

  Future<void> close() => connection.close();
}
