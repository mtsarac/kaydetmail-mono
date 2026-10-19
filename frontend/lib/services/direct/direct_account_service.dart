import 'dart:math';

import 'package:flutter/foundation.dart';

import 'certificate_hint.dart';
import 'direct_account_runtime.dart';
import 'direct_account_setup.dart';
import 'direct_credential_store.dart';
import 'direct_errors.dart';
import 'direct_mail_gateway.dart';
import 'direct_store.dart';
import 'enough_imap_service.dart';
import 'sync_engine.dart';

/// Checks the outgoing server accepts the account (connect, secure, sign in,
/// no mail sent). Throws a `DirectMailException` when it does not.
typedef SmtpVerifier = Future<void> Function(
  DirectEndpoint endpoint,
  String password,
);

/// Finds a host the server's certificate covers, for a certificate error.
typedef CertificateHostSuggester = Future<String?> Function(
  DirectEndpoint endpoint,
);

/// Creates, restores and removes direct accounts: the part of the engine
/// that knows about passwords and servers, as opposed to mail.
class DirectAccountService {
  DirectAccountService({
    DirectCredentialStore? credentials,
    ImapFactory? imapFactory,
    SmtpFactory? smtpFactory,
    CertificateHostSuggester? suggestHost,
    this._isOnline,
    String Function()? newId,
    this.syncOptions = const SyncOptions(),
    this.staleAfter = const Duration(seconds: 30),
  }) : credentials = credentials ?? DirectCredentialStore(),
       _imapFactory = imapFactory ?? _realImap,
       _smtpFactory = smtpFactory ?? defaultSmtpFactory,
       _suggestHost = suggestHost ?? CertificateHint.forServer,
       _newId = newId ?? _randomId;

  final DirectCredentialStore credentials;
  final ImapFactory _imapFactory;
  final SmtpFactory _smtpFactory;
  final CertificateHostSuggester _suggestHost;
  final Future<bool> Function()? _isOnline;
  final String Function() _newId;
  final SyncOptions syncOptions;
  final Duration staleAfter;

  static EnoughImapService _realImap(
    DirectEndpoint endpoint,
    String password,
  ) => EnoughImapService(endpoint: endpoint, password: password);

  static String _randomId() {
    final random = Random.secure();
    return 'da-${[for (var i = 0; i < 12; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
  }

  /// Signs in to both servers with what the user entered. Nothing is stored.
  /// A certificate that does not match the server name is reported with the
  /// host name the certificate does cover, when it can be read.
  @visibleForTesting
  Future<void> verify(DirectAccountSetup setup) async {
    final imap = _imapFactory(setup.imap, setup.password);
    try {
      await imap.connect();
      // Listing the folders proves the account really reads mail, not only
      // that the password was accepted.
      await imap.listFolders();
    } on DirectMailException catch (error) {
      throw await _explainCertificate(error, setup.imap);
    } finally {
      await imap.disconnect();
    }
    try {
      // Signing in to the outgoing server proves the settings and password;
      // nothing is sent.
      await _smtpFactory(
        setup.smtp,
        setup.effectiveSmtpPassword,
        _domainOf(setup.email),
      ).verify();
    } on DirectMailException catch (error) {
      throw await _explainCertificate(error, setup.smtp);
    }
  }

  static String _domainOf(String email) {
    final at = email.lastIndexOf('@');
    return at < 0 || at == email.length - 1
        ? 'localhost'
        : email.substring(at + 1).trim();
  }

  Future<DirectMailException> _explainCertificate(
    DirectMailException error,
    DirectEndpoint endpoint,
  ) async {
    if (error.kind != DirectErrorKind.tlsCertificateInvalid) return error;
    final suggestion = await _suggestHost(endpoint);
    return suggestion == null
        ? error
        : DirectMailException(
            DirectErrorKind.tlsCertificateInvalid,
            suggestedHost: suggestion,
            cause: error.cause,
          );
  }

  /// Verifies [setup], stores the account and its passwords and returns the
  /// running account. [existingEmails] guards against adding a mailbox twice.
  Future<DirectMailGateway> add(
    DirectAccountSetup setup,
    DirectStore store, {
    Iterable<String> existingEmails = const [],
  }) async {
    final email = setup.email.trim();
    final taken = {
      for (final e in existingEmails) e.toLowerCase(),
      for (final a in store.accounts()) a.email.toLowerCase(),
    };
    if (taken.contains(email.toLowerCase())) {
      throw DirectMailException(DirectErrorKind.accountExists);
    }
    await verify(setup);
    final config = DirectAccountConfig(
      id: _newId(),
      email: email,
      displayName: setup.displayName.trim(),
      imap: setup.imap,
      smtp: setup.smtp,
    );
    final secrets = DirectCredentials(
      imapPassword: setup.password,
      smtpPassword: setup.smtpPassword,
    );
    await credentials.save(config.id, secrets);
    store.saveAccount(config);
    return _open(config, secrets, store);
  }

  /// The running account for a stored one. Without its passwords (the
  /// keystore was wiped, the device restored) the account opens locked, so
  /// its mail can still be read and the user is asked for the password.
  Future<DirectMailGateway?> restore(
    String accountId,
    DirectStore store,
  ) async {
    final config = store.account(accountId);
    if (config == null) return null;
    final secrets = await credentials.read(accountId);
    final gateway = _open(
      config,
      secrets ?? const DirectCredentials(imapPassword: ''),
      store,
    );
    if (secrets == null) {
      gateway.runtime.connection.policy.failed(
        DirectMailException(DirectErrorKind.authFailed),
      );
    }
    return gateway;
  }

  DirectMailGateway _open(
    DirectAccountConfig config,
    DirectCredentials secrets,
    DirectStore store,
  ) {
    final runtime = DirectAccountRuntime(
      config: config,
      credentials: secrets,
      imapFactory: _imapFactory,
      smtpFactory: _smtpFactory,
      credentialStore: credentials,
      isOnline: _isOnline,
    );
    runtime.onDeleted = () => credentials.clear(config.id);
    return DirectMailGateway(
      runtime: runtime,
      store: store,
      syncOptions: syncOptions,
      staleAfter: staleAfter,
    );
  }
}
