import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/account_capabilities.dart';
import 'package:kaydetmail/models/mail_account.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_credential_store.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/utils/error_messages.dart';

import 'support/memory_token_storage.dart';

const _imap = DirectEndpoint(
  host: 'imap.example.com',
  port: 993,
  security: MailSecurity.sslOnConnect,
  username: 'ada@example.com',
);
const _smtp = DirectEndpoint(
  host: 'smtp.example.com',
  port: 587,
  security: MailSecurity.startTls,
  username: 'ada@example.com',
);

void main() {
  group('DirectMailException', () {
    test('is an ApiException so existing handling applies', () {
      final error = DirectMailException(DirectErrorKind.authFailed);
      expect(error, isA<ApiException>());
      expect(error.category, ApiErrorCategory.authentication);
      expect(error.isTransient, isFalse);
    });

    test('offline and timeout reuse the HTTP client codes', () {
      expect(DirectErrorKind.offline.code, 'network_unavailable');
      expect(DirectErrorKind.connectionTimeout.code, 'request_timeout');
      expect(DirectErrorKind.deliveryUncertain.code, 'delivery_unknown');
      expect(
        DirectMailException(DirectErrorKind.offline).category,
        ApiErrorCategory.network,
      );
      expect(
        DirectMailException(DirectErrorKind.connectionTimeout).category,
        ApiErrorCategory.timeout,
      );
    });

    test('rate limits and temporary failures are retryable', () {
      expect(
        DirectMailException(DirectErrorKind.rateLimited).isTransient,
        true,
      );
      expect(
        DirectMailException(DirectErrorKind.temporaryFailure).isTransient,
        true,
      );
      expect(
        DirectMailException(DirectErrorKind.smtpRecipientRejected).isTransient,
        false,
      );
    });

    test('every kind has its own user-facing text', () {
      final messages = {
        for (final kind in DirectErrorKind.values)
          kind: DirectMailException(kind).userMessage,
      };
      for (final entry in messages.entries) {
        expect(entry.value, isNotEmpty, reason: '${entry.key}');
      }
      // The failures a user has to tell apart must not read the same.
      final distinct = [
        DirectErrorKind.dnsFailure,
        DirectErrorKind.hostUnreachable,
        DirectErrorKind.tlsHandshakeFailed,
        DirectErrorKind.tlsCertificateInvalid,
        DirectErrorKind.authFailed,
        DirectErrorKind.smtpRejected,
        DirectErrorKind.rateLimited,
      ].map((k) => messages[k]).toSet();
      expect(distinct, hasLength(7));
    });

    test('a certificate for another host suggests that host', () {
      final error = DirectMailException(
        DirectErrorKind.tlsCertificateInvalid,
        suggestedHost: 'server12.hosting.example',
      );
      expect(error.userMessage, contains('server12.hosting.example'));
    });

    test('friendlyErrorMessage never leaks the cause', () {
      final error = DirectMailException(
        DirectErrorKind.imapCommandFailed,
        cause: StateError('A1 NO [AUTHENTICATIONFAILED] secret-host.internal'),
      );
      expect(friendlyErrorMessage(error), isNot(contains('secret-host')));
      expect('$error', isNot(contains('secret-host')));
    });

    test('sockets and the TLS stack map to distinct kinds', () {
      DirectErrorKind kindOf(Object e) => DirectMailException.from(e).kind;
      expect(
        kindOf(
          const SocketException(
            'Failed host lookup: imap.nope.test',
            osError: OSError('No address associated with hostname', 7),
          ),
        ),
        DirectErrorKind.dnsFailure,
      );
      expect(
        kindOf(
          const SocketException(
            'Connection refused',
            osError: OSError('Connection refused', 111),
          ),
        ),
        DirectErrorKind.hostUnreachable,
      );
      expect(
        kindOf(
          const SocketException(
            'Connection timed out',
            osError: OSError('Connection timed out', 110),
          ),
        ),
        DirectErrorKind.connectionTimeout,
      );
      expect(
        kindOf(TimeoutException('slow')),
        DirectErrorKind.connectionTimeout,
      );
      expect(
        kindOf(
          const HandshakeException(
            'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: '
            'Hostname mismatch)',
          ),
        ),
        DirectErrorKind.tlsCertificateInvalid,
      );
      expect(
        kindOf(const HandshakeException('WRONG_VERSION_NUMBER')),
        DirectErrorKind.tlsHandshakeFailed,
      );
    });

    test('an existing DirectMailException is returned as is', () {
      final original = DirectMailException(DirectErrorKind.authFailed);
      expect(identical(DirectMailException.from(original), original), isTrue);
    });
  });

  group('DirectAccountSetup', () {
    DirectAccountSetup setup({
      String email = 'ada@example.com',
      String password = 'pw',
      DirectEndpoint imap = _imap,
      DirectEndpoint smtp = _smtp,
    }) => DirectAccountSetup(
      email: email,
      displayName: 'Ada',
      password: password,
      imap: imap,
      smtp: smtp,
    );

    test('accepts a complete setup', () {
      expect(setup().problem, isNull);
    });

    test('names the first wrong field', () {
      expect(setup(email: 'nope').problem, DirectSetupProblem.email);
      expect(setup(password: '').problem, DirectSetupProblem.password);
      expect(
        setup(imap: _imap.copyWith(host: 'imap example')).problem,
        DirectSetupProblem.host,
      );
      expect(
        setup(smtp: _smtp.copyWith(port: 70000)).problem,
        DirectSetupProblem.port,
      );
      expect(
        setup(imap: _imap.copyWith(username: ' ')).problem,
        DirectSetupProblem.username,
      );
    });

    test('host names cannot carry a scheme, path or spaces', () {
      for (final bad in [
        'https://imap.example.com',
        'imap.example.com/x',
        'imap.example.com:993',
        'imap example.com',
        '',
        '-bad.example.com',
      ]) {
        expect(DirectEndpoint.isValidHostName(bad), isFalse, reason: bad);
      }
      for (final good in ['imap.example.com', 'localhost', '127.0.0.1']) {
        expect(DirectEndpoint.isValidHostName(good), isTrue, reason: good);
      }
    });

    test('SMTP falls back to the account password', () {
      expect(setup().effectiveSmtpPassword, 'pw');
      expect(
        setup().copyWith(smtpPassword: 'other').effectiveSmtpPassword,
        'other',
      );
    });

    test('an endpoint survives a JSON round trip', () {
      expect(DirectEndpoint.fromJson(_smtp.toJson()), _smtp);
      expect(DirectEndpoint.fromJson(_imap.toJson()), _imap);
    });
  });

  group('DirectCredentialStore', () {
    test('keeps each account separate and can forget one', () async {
      final storage = MemoryTokenStorage();
      final store = DirectCredentialStore(storage: storage);
      await store.save(
        'a',
        const DirectCredentials(imapPassword: 'pa', smtpPassword: 'sa'),
      );
      await store.save('b', const DirectCredentials(imapPassword: 'pb'));

      expect((await store.read('a'))?.imapPassword, 'pa');
      expect((await store.read('a'))?.effectiveSmtpPassword, 'sa');
      expect((await store.read('b'))?.effectiveSmtpPassword, 'pb');

      await store.clear('a');
      expect(await store.read('a'), isNull);
      expect((await store.read('b'))?.imapPassword, 'pb');
    });

    test('a damaged record reads as missing', () async {
      final storage = MemoryTokenStorage();
      storage.values['kaydet.direct.a.credentials'] = '{not json';
      expect(await DirectCredentialStore(storage: storage).read('a'), isNull);
    });
  });

  group('capabilities', () {
    test('direct accounts name what they lack', () {
      const direct = AccountCapabilities.direct();
      const backend = AccountCapabilities.backend();
      expect(direct.isDirect, isTrue);
      expect(direct.guaranteedScheduledSend, isFalse);
      expect(direct.deviceSessions, isFalse);
      expect(direct.serverPush, isFalse);
      expect(direct.crossDeviceMetadata, isFalse);
      expect(backend.guaranteedScheduledSend, isTrue);
      expect(backend.deviceSessions, isTrue);
    });

    test('an account keeps its mode through copyWith', () {
      const account = MailAccount(
        id: 'a',
        email: 'ada@example.com',
        mode: AccountMode.direct,
      );
      expect(account.copyWith(displayName: 'Ada').isDirect, isTrue);
      expect(
        const MailAccount(id: 'b', email: 'b@example.com').isDirect,
        isFalse,
      );
    });

    test('the mode is stored as a stable word', () {
      expect(AccountMode.fromStorage('direct'), AccountMode.direct);
      expect(AccountMode.fromStorage('backend'), AccountMode.backend);
      expect(AccountMode.fromStorage(null), AccountMode.backend);
      expect(AccountMode.direct.storageValue, 'direct');
    });
  });
}
