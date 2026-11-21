import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/enough_imap_service.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:enough_mail_plus/enough_mail.dart'
    show ImapException, ImapClient;

ImapException _error(String message) => ImapException(ImapClient(), message);

void main() {
  group('INTERNALDATE', () {
    test('is read as UTC, whatever the zone it was written in', () {
      expect(
        EnoughImapService.parseInternalDate('19-Oct-2026 00:22:55 +0000'),
        DateTime.utc(2026, 10, 19, 0, 22, 55),
      );
      expect(
        EnoughImapService.parseInternalDate('06-Oct-2025 10:00:00 +0300'),
        DateTime.utc(2025, 10, 6, 7),
      );
      expect(
        EnoughImapService.parseInternalDate('06-Oct-2025 10:00:00 -0530'),
        DateTime.utc(2025, 10, 6, 15, 30),
      );
    });

    test('a day without a leading zero and any month case are accepted', () {
      expect(
        EnoughImapService.parseInternalDate(' 6-OCT-2025 01:02:03 +0000'),
        DateTime.utc(2025, 10, 6, 1, 2, 3),
      );
    });

    test('anything else is null, never an exception', () {
      for (final bad in [
        null,
        '',
        'yesterday',
        '19/10/2026',
        '19-Foo-2026 00:00:00 +0000',
      ]) {
        expect(
          EnoughImapService.parseInternalDate(bad),
          isNull,
          reason: '$bad',
        );
      }
    });
  });

  group('sign-in failures', () {
    DirectErrorKind kind(String text) =>
        EnoughImapService.classifyLoginFailure(_error(text)).kind;

    test('a refused password is an authentication failure', () {
      expect(
        kind('LOGIN failed. Invalid login/password for user id bob'),
        DirectErrorKind.authFailed,
      );
      expect(
        kind('NO [AUTHENTICATIONFAILED] Authentication failed.'),
        DirectErrorKind.authFailed,
      );
    });

    test('providers that require an app password say so', () {
      expect(
        kind(
          'NO [ALERT] Application-specific password required: https://support.google.com/accounts/answer/185833',
        ),
        DirectErrorKind.authRequiresAppPassword,
      );
      expect(
        kind('NO [ALERT] Web login required'),
        DirectErrorKind.authRequiresAppPassword,
      );
    });

    test('rate limits and busy servers are not "wrong password"', () {
      expect(
        kind('NO [UNAVAILABLE] Temporary authentication failure'),
        DirectErrorKind.temporaryFailure,
      );
      expect(
        kind('NO [LIMIT] Too many connections from your IP'),
        DirectErrorKind.rateLimited,
      );
      expect(
        kind('NO too many login failures, try again later'),
        DirectErrorKind.rateLimited,
      );
    });

    test('a server that wants TLS first is a TLS problem', () {
      expect(
        kind(
          'NO [PRIVACYREQUIRED] Plaintext authentication disallowed, LOGINDISABLED',
        ),
        DirectErrorKind.tlsHandshakeFailed,
      );
    });

    test('the user name is never part of what the user sees', () {
      final e = EnoughImapService.classifyLoginFailure(
        _error(
          'LOGIN failed. Invalid login/password for user id bob@secret.test',
        ),
      );
      expect(e.userMessage, isNot(contains('bob')));
      expect('$e', isNot(contains('bob')));
    });
  });

  group('failed commands', () {
    DirectErrorKind kind(String text) =>
        EnoughImapService.classifyImapFailure(_error(text)).kind;

    test('missing folders', () {
      expect(
        kind('SELECT failed. No such mailbox'),
        DirectErrorKind.folderNotFound,
      );
      expect(
        kind('NO [NONEXISTENT] Mailbox doesn\'t exist: Foo'),
        DirectErrorKind.folderNotFound,
      );
      expect(
        kind('NO [TRYCREATE] no such mailbox'),
        DirectErrorKind.folderNotFound,
      );
    });

    test('quota, throttling and temporary trouble', () {
      expect(
        kind('NO [OVERQUOTA] Quota exceeded'),
        DirectErrorKind.quotaExceeded,
      );
      expect(kind('NO [LIMIT] too many commands'), DirectErrorKind.rateLimited);
      expect(
        kind('NO [UNAVAILABLE] try again later'),
        DirectErrorKind.temporaryFailure,
      );
    });

    test('anything unrecognised is a generic server refusal', () {
      expect(kind('BAD something odd'), DirectErrorKind.imapCommandFailed);
    });
  });

  group('capabilities', () {
    test('are read case-insensitively from the raw list', () {
      final c = ImapCapabilities.fromNames([
        'imap4rev1',
        'Idle',
        'UIDPLUS',
        'MOVE',
        'CONDSTORE',
      ]);
      expect(
        [c.idle, c.uidPlus, c.move, c.condStore, c.qresync],
        [true, true, true, true, false],
      );
      expect(ImapCapabilities.fromNames(['QRESYNC']).condStore, isTrue);
    });
  });

  group('copy results', () {
    test('map each source UID to its new UID', () {
      const r = RemoteCopyResult(
        uidValidity: 5,
        sourceUids: [3, 4],
        targetUids: [10, 11],
      );
      expect(r.targetFor(4), 11);
      expect(r.targetFor(9), isNull);
      expect(const RemoteCopyResult().targetFor(3), isNull);
      expect(
        const RemoteCopyResult(
          sourceUids: [1, 2],
          targetUids: [9],
        ).targetFor(1),
        isNull,
        reason: 'mismatched lists are not trusted',
      );
    });
  });
}
