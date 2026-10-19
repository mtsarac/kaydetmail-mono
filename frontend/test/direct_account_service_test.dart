import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_service.dart';
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_credential_store.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/fake_imap_service.dart';
import 'support/memory_token_storage.dart';

DirectAccountSetup _setup({
  String email = 'ayse@example.test',
  String password = 'gizli',
  String? smtpPassword,
}) => DirectAccountSetup(
  email: email,
  displayName: 'Ayşe',
  password: password,
  smtpPassword: smtpPassword,
  imap: DirectEndpoint(
    host: 'mail.example.test',
    port: 993,
    security: MailSecurity.sslOnConnect,
    username: email,
  ),
  smtp: DirectEndpoint(
    host: 'mail.example.test',
    port: 465,
    security: MailSecurity.sslOnConnect,
    username: email,
  ),
);

void main() {
  late FakeImapService imap;
  late DirectStore store;
  late DirectCredentialStore credentials;
  late List<String> imapPasswords;
  late List<String> smtpPasswords;
  late List<String> suggestionsAskedFor;
  var n = 0;

  DirectAccountService service({Object? smtpFailure, String? suggestion}) =>
      DirectAccountService(
        credentials: credentials,
        imapFactory: (endpoint, password) {
          imapPasswords.add(password);
          return imap;
        },
        smtpVerifier: (endpoint, password) async {
          smtpPasswords.add(password);
          if (smtpFailure != null) throw smtpFailure;
        },
        suggestHost: (endpoint) async {
          suggestionsAskedFor.add(endpoint.host);
          return suggestion;
        },
        newId: () => 'da-${++n}',
      );

  setUp(() {
    n = 0;
    imap = FakeImapService()..addFolder('INBOX', use: FolderRole.inbox);
    store = DirectStore(sqlite3.openInMemory());
    credentials = DirectCredentialStore(storage: MemoryTokenStorage());
    imapPasswords = [];
    smtpPasswords = [];
    suggestionsAskedFor = [];
  });

  test(
    'adding verifies both servers, then keeps the account and passwords',
    () async {
      final gateway = await service().add(_setup(), store);
      expect(imapPasswords, ['gizli']);
      expect(smtpPasswords, ['gizli']);
      expect(gateway.accountId, 'da-1');
      expect(store.account('da-1')!.email, 'ayse@example.test');
      expect((await credentials.read('da-1'))!.imapPassword, 'gizli');
      expect((await gateway.getAccount()).isDirect, isTrue);
      await gateway.dispose();
    },
  );

  test('a separate outgoing password is used for the outgoing check', () async {
    final gateway = await service().add(_setup(smtpPassword: 'baska'), store);
    expect(smtpPasswords, ['baska']);
    expect((await credentials.read('da-1'))!.effectiveSmtpPassword, 'baska');
    await gateway.dispose();
  });

  test('a refused password stores nothing', () async {
    imap.failNext('connect', DirectMailException(DirectErrorKind.authFailed));
    await expectLater(
      service().add(_setup(), store),
      throwsA(
        isA<DirectMailException>().having(
          (e) => e.kind,
          'kind',
          DirectErrorKind.authFailed,
        ),
      ),
    );
    expect(store.accounts(), isEmpty);
    expect(await credentials.read('da-1'), isNull);
  });

  test('a refused outgoing server stores nothing', () async {
    final failing = service(
      smtpFailure: DirectMailException(DirectErrorKind.smtpRejected),
    );
    await expectLater(
      failing.add(_setup(), store),
      throwsA(isA<DirectMailException>()),
    );
    expect(store.accounts(), isEmpty);
  });

  test('the same mailbox cannot be added twice', () async {
    final first = await service().add(_setup(), store);
    await expectLater(
      service().add(_setup(email: 'AYSE@example.test'), store),
      throwsA(
        isA<DirectMailException>().having(
          (e) => e.code,
          'code',
          'mail_account_already_exists',
        ),
      ),
    );
    expect(store.accounts(), hasLength(1));
    await first.dispose();
  });

  test('a mailbox connected another way counts as taken', () async {
    await expectLater(
      service().add(_setup(), store, existingEmails: ['ayse@example.test']),
      throwsA(isA<DirectMailException>()),
    );
  });

  test('a certificate error names the host the certificate covers', () async {
    imap.failNext(
      'connect',
      DirectMailException(DirectErrorKind.tlsCertificateInvalid),
    );
    await expectLater(
      service(suggestion: 'mail.hosting.example').add(_setup(), store),
      throwsA(
        isA<DirectMailException>()
            .having(
              (e) => e.kind,
              'kind',
              DirectErrorKind.tlsCertificateInvalid,
            )
            .having(
              (e) => e.suggestedHost,
              'suggestedHost',
              'mail.hosting.example',
            ),
      ),
    );
    expect(suggestionsAskedFor, ['mail.example.test']);
  });

  test('other failures are not second-guessed', () async {
    imap.failNext('connect', DirectMailException(DirectErrorKind.authFailed));
    await expectLater(
      service(suggestion: 'x.example').add(_setup(), store),
      throwsA(isA<DirectMailException>()),
    );
    expect(suggestionsAskedFor, isEmpty);
  });

  test('restoring brings back the account with its passwords', () async {
    final created = await service().add(_setup(), store);
    await created.dispose();
    imapPasswords.clear();
    final restored = await service().restore('da-1', store);
    expect(restored, isNotNull);
    expect(restored!.runtime.credentials.imapPassword, 'gizli');
    await restored.getFolders();
    expect(imapPasswords, ['gizli']);
    await restored.dispose();
  });

  test('restoring without the passwords opens a locked account', () async {
    final created = await service().add(_setup(), store);
    await created.dispose();
    await credentials.clear('da-1');
    final restored = (await service().restore('da-1', store))!;
    expect((await restored.getAccount()).status.name, 'needsReauthentication');
    imap.resetCalls();
    await expectLater(
      restored.getFolders(),
      throwsA(isA<DirectMailException>()),
    );
    expect(imap.count('connect'), 0);
    await restored.dispose();
  });

  test('an unknown account does not restore', () async {
    expect(await service().restore('da-9', store), isNull);
  });

  test('deleting the account clears its passwords and mail', () async {
    final gateway = await service().add(_setup(), store);
    await gateway.deleteAccount();
    expect(store.accounts(), isEmpty);
    expect(await credentials.read('da-1'), isNull);
  });
}
