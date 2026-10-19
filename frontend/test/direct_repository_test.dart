import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/repositories/api_mail_repository.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_service.dart';
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_credential_store.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:kaydetmail/services/mail_cache.dart';
import 'package:kaydetmail/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/direct_rig.dart';
import 'support/fake_imap_service.dart';
import 'support/fake_smtp_sender.dart';
import 'support/memory_token_storage.dart';

DirectAccountSetup _setup(String email) => DirectAccountSetup(
  email: email,
  displayName: 'Ayşe',
  password: 'gizli',
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

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MailCache cache;
  late MemoryTokenStorage keystore;
  late FakeImapService imap;
  late FakeSmtpSender smtp;

  DirectAccountService accounts({
    Duration staleAfter = const Duration(minutes: 5),
  }) => DirectAccountService(
    credentials: DirectCredentialStore(storage: keystore),
    imapFactory: (_, _) => imap,
    smtpFactory: (_, _, _) => smtp,
    suggestHost: (_) async => null,
    syncOptions: const SyncOptions(prefetchBodies: 0),
    staleAfter: staleAfter,
  );

  ApiMailRepository repository({
    Duration staleAfter = const Duration(minutes: 5),
  }) => ApiMailRepository(
    openCache: () async => cache,
    directAccountService: accounts(staleAfter: staleAfter),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache = MailCache.inMemory();
    keystore = MemoryTokenStorage();
    smtp = FakeSmtpSender();
    imap = FakeImapService()
      ..addFolder('INBOX', use: FolderRole.inbox)
      ..addFolder('Sent', use: FolderRole.sent);
  });

  test(
    'a direct account connects, lists its mail and keeps its mode',
    () async {
      imap.add('INBOX', rigMail('a', subject: 'Merhaba'));
      imap.add('INBOX', rigMail('b', subject: 'Toplantı'));
      final repo = repository();
      final account = await repo.connectDirectAccount(
        _setup('ayse@example.test'),
      );

      expect(account.isDirect, isTrue);
      expect(repo.accounts.single.email, 'ayse@example.test');
      expect(repo.capabilitiesOf(account.id).deviceSessions, isFalse);
      expect(repo.capabilitiesOf(account.id).serverPush, isFalse);

      await repo.refreshEmails(MailFolder.inbox);
      final inbox = repo.getEmailsInFolder(MailFolder.inbox);
      expect(inbox.map((e) => e.subject), ['Toplantı', 'Merhaba']);
      expect(inbox.every((e) => e.accountId == account.id), isTrue);
      expect(repo.isOffline, isFalse);
      expect(
        (await SessionStore.loadDirectAccount('ayse@example.test'))!.id,
        account.id,
      );
    },
  );

  test('opening a mail reads its body from the server once', () async {
    imap.add('INBOX', rigMail('a', body: 'gövde'));
    final repo = repository();
    await repo.connectDirectAccount(_setup('ayse@example.test'));
    await repo.refreshEmails(MailFolder.inbox);
    final id = repo.getEmailsInFolder(MailFolder.inbox).single.id;
    final email = await repo.getEmail(id);
    expect(email!.bodyText, contains('gövde'));
  });

  test('the same mailbox cannot be connected twice', () async {
    final repo = repository();
    await repo.connectDirectAccount(_setup('ayse@example.test'));
    await expectLater(
      repo.connectDirectAccount(_setup('ayse@example.test')),
      throwsA(
        isA<DirectMailException>().having(
          (e) => e.code,
          'code',
          'mail_account_already_exists',
        ),
      ),
    );
    expect(repo.accounts, hasLength(1));
  });

  test('a refused password adds nothing', () async {
    imap.failNext('connect', DirectMailException(DirectErrorKind.authFailed));
    final repo = repository();
    await expectLater(
      repo.connectDirectAccount(_setup('ayse@example.test')),
      throwsA(isA<DirectMailException>()),
    );
    expect(repo.accounts, isEmpty);
    expect(await SessionStore.loadDirectAccounts(), isEmpty);
  });

  test(
    'after a restart the account comes back with its mail, offline too',
    () async {
      imap.add('INBOX', rigMail('a', subject: 'Saklı'));
      final first = repository();
      final account = await first.connectDirectAccount(
        _setup('ayse@example.test'),
      );
      await first.refreshEmails(MailFolder.inbox);

      // New app process: same device storage, server unreachable.
      imap.failNext(
        'connect',
        DirectMailException(DirectErrorKind.hostUnreachable),
        times: 20,
      );
      final second = repository();
      await second.restoreSession('ayse@example.test');
      expect(second.accounts.single.id, account.id);
      await second.refreshEmails(MailFolder.inbox);
      expect(second.getEmailsInFolder(MailFolder.inbox).map((e) => e.subject), [
        'Saklı',
      ]);
    },
  );

  test(
    'the repository learns of mail that arrives in the background',
    () async {
      imap.add('INBOX', rigMail('a', subject: 'Eski'));
      final repo = repository(staleAfter: Duration.zero);
      await repo.connectDirectAccount(_setup('ayse@example.test'));
      await repo.refreshEmails(MailFolder.inbox);
      imap.add('INBOX', rigMail('b', subject: 'Yeni'));

      var notified = 0;
      repo.addListener(() => notified++);
      await repo.refreshEmails(
        MailFolder.inbox,
      ); // stale: answers, syncs behind
      await _until(
        () => repo
            .getEmailsInFolder(MailFolder.inbox)
            .any((e) => e.subject == 'Yeni'),
      );
      expect(notified, greaterThan(0));
    },
  );

  test('losing and regaining the server flips the offline state', () async {
    imap.add('INBOX', rigMail('a'));
    final repo = repository(staleAfter: Duration.zero);
    await repo.connectDirectAccount(_setup('ayse@example.test'));
    await repo.refreshEmails(MailFolder.inbox);
    expect(repo.isOffline, isFalse);

    imap.failNext(
      'select',
      DirectMailException(DirectErrorKind.hostUnreachable),
    );
    await repo.refreshEmails(MailFolder.inbox); // background pass fails
    await _until(() => repo.isOffline);
  });

  test(
    'removing the account deletes its mail, passwords and registry entry',
    () async {
      imap.add('INBOX', rigMail('a'));
      final repo = repository();
      final account = await repo.connectDirectAccount(
        _setup('ayse@example.test'),
      );
      await repo.refreshEmails(MailFolder.inbox);
      await repo.removeAccount(account.id);

      expect(repo.accounts, isEmpty);
      expect(await SessionStore.loadDirectAccounts(), isEmpty);
      expect(
        await DirectCredentialStore(storage: keystore).read(account.id),
        isNull,
      );
      final rows = cache.db
          .select('SELECT COUNT(*) AS n FROM d_messages')
          .first['n'];
      expect(rows, 0);
    },
  );

  test('signing out removes direct accounts from the device', () async {
    final repo = repository();
    final account = await repo.connectDirectAccount(
      _setup('ayse@example.test'),
    );
    await repo.logout();
    expect(repo.accounts, isEmpty);
    expect(
      await DirectCredentialStore(storage: keystore).read(account.id),
      isNull,
    );
    expect(await SessionStore.loadEmails(), isEmpty);
  });

  test('a backend-only repository refuses direct accounts politely', () async {
    final repo = ApiMailRepository(openCache: () async => cache);
    // Without an injected service a real one is built, but discovery needs
    // no network for known providers.
    final settings = await repo.discoverDirectSettings('x@gmail.com');
    expect(settings!.imap.host, 'imap.gmail.com');
  });
}
