@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/email.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_runtime.dart';
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_credential_store.dart';
import 'package:kaydetmail/services/direct/direct_mail_gateway.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/enough_imap_service.dart';
import 'package:kaydetmail/services/direct/message_composer.dart';
import 'package:kaydetmail/services/direct/smtp_sender.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/integration_environment.dart';

/// The whole direct gateway on the real adapters, against a real server:
/// what the unit tests assume about IMAP and SMTP servers is exercised here
/// end to end (send, receive, flag, move, rename, draft, search, watch).
void main() {
  final skip = IntegrationEnvironment.skipUnlessGreenMail;
  const self = 'test@localhost';

  void check(String name, Future<void> Function() body) =>
      test(name, body, skip: skip);

  MailFolder resolve(String id) => MailFolder.inbox;

  EnoughImapService rawImap() => EnoughImapService(
    endpoint: DirectEndpoint(
      host: IntegrationEnvironment.host,
      port: IntegrationEnvironment.imapPort,
      security: MailSecurity.startTls,
      username: IntegrationEnvironment.user,
    ),
    password: IntegrationEnvironment.password,
    transport: ImapTransport.plaintext,
    connectTimeout: const Duration(seconds: 5),
    responseTimeout: const Duration(seconds: 15),
  );

  late DirectMailGateway gateway;
  late DirectStore store;

  /// Empties every folder, so each test starts from nothing in the mailbox.
  Future<void> clean() async {
    final cleaner = rawImap();
    await cleaner.connect();
    for (final f in await cleaner.listFolders()) {
      final uids = await cleaner.listUids(f.path);
      if (uids.isNotEmpty) await cleaner.expunge(f.path, uids);
    }
    await cleaner.disconnect();
  }

  setUp(() async {
    if (!IntegrationEnvironment.greenMailEnabled) return;
    await clean();
    store = DirectStore(sqlite3.openInMemory());
    final runtime = DirectAccountRuntime(
      config: DirectAccountConfig(
        id: 'gm',
        email: self,
        displayName: 'Test Kullanıcı',
        imap: DirectEndpoint(
          host: IntegrationEnvironment.host,
          port: IntegrationEnvironment.imapPort,
          security: MailSecurity.startTls,
          username: IntegrationEnvironment.user,
        ),
        smtp: DirectEndpoint(
          host: IntegrationEnvironment.host,
          port: IntegrationEnvironment.smtpPort,
          security: MailSecurity.startTls,
          username: IntegrationEnvironment.user,
        ),
      ),
      credentials: DirectCredentials(
        imapPassword: IntegrationEnvironment.password,
      ),
      imapFactory: (endpoint, password) => EnoughImapService(
        endpoint: endpoint,
        password: password,
        transport: ImapTransport.plaintext,
        connectTimeout: const Duration(seconds: 5),
        responseTimeout: const Duration(seconds: 15),
      ),
      smtpFactory: (endpoint, password, domain) => EnoughSmtpSender(
        endpoint: endpoint,
        password: password,
        clientDomain: domain,
        transport: SmtpTransport.plaintext,
        connectTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 20),
      ),
    );
    gateway = DirectMailGateway(
      runtime: runtime,
      store: store,
      syncOptions: const SyncOptions(prefetchBodies: 0),
      staleAfter: Duration.zero,
      schedulerTick: null,
      backgroundGrace: Duration.zero,
    );
  });

  tearDown(() async {
    if (IntegrationEnvironment.greenMailEnabled) await gateway.dispose();
  });

  Future<String> folderId(String type) async => (await gateway.getFolders())
      .firstWhere((f) => f.type == type || f.fullName == type)
      .id;

  /// Reads the folder until [count] messages are listed (delivery is quick
  /// but not instantaneous).
  Future<List<Email>> list(String folder, {int count = 1}) async {
    final id = await folderId(folder);
    for (var i = 0; i < 50; i++) {
      await gateway.syncFolderId(id);
      final page = await gateway.getMails(folderId: id, resolveFolder: resolve);
      if (page.items.length >= count) return page.items;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('$folder never held $count messages');
  }

  /// What the server itself holds in [folder], read by a separate session.
  Future<List<({int uid, Set<String> flags})>> onServer(String path) async {
    final raw = rawImap();
    await raw.connect();
    try {
      await raw.select(path);
      return [
        for (final f in await raw.fetchFlags(path, fromUid: 1))
          (uid: f.uid, flags: f.flags),
      ];
    } finally {
      await raw.disconnect();
    }
  }

  check(
    'sending to oneself: it arrives, a copy is filed, Turkish survives',
    () async {
      final result = await gateway.sendMail(
        to: [self],
        subject: 'Çağrı toplantısı — şubat',
        bodyText: 'Merhaba, yarın saat 10’da görüşelim. ğüşıöç',
        idempotencyKey: 'k1',
      );
      expect(result.sent, isTrue);
      expect(result.sentCopySaved, isTrue);

      final inbox = await list('Inbox');
      expect(inbox.single.subject, 'Çağrı toplantısı — şubat');
      final mail = await gateway.getMail(
        inbox.single.id,
        resolveFolder: resolve,
      );
      expect(mail.bodyText, contains('ğüşıöç'));
      expect(mail.senderEmail, self);
      expect(await onServer('Sent'), hasLength(1));

      // A retry under the same key delivers nothing more.
      await gateway.sendMail(to: [self], subject: 'x', idempotencyKey: 'k1');
      expect((await list('Inbox')).length, 1);
    },
  );

  check('flags reach the server and come back', () async {
    await gateway.sendMail(
      to: [self],
      subject: 'Bayraklar',
      idempotencyKey: 'k1',
    );
    final id = (await list('Inbox')).single.id;
    await gateway.mailAction(id, 'read');
    await gateway.mailAction(id, 'star');
    var server = await onServer('INBOX');
    expect(server.single.flags, containsAll([r'\Seen', r'\Flagged']));
    await gateway.mailAction(id, 'unread');
    await gateway.mailAction(id, 'unstar');
    server = await onServer('INBOX');
    expect(server.single.flags, isNot(contains(r'\Seen')));
    expect(server.single.flags, isNot(contains(r'\Flagged')));
  });

  check('trash, restore and archive keep the mail and its id', () async {
    await gateway.sendMail(
      to: [self],
      subject: 'Taşınan',
      idempotencyKey: 'k1',
    );
    final id = (await list('Inbox')).single.id;

    await gateway.mailAction(id, 'trash');
    expect(await onServer('INBOX'), isEmpty);
    expect(await onServer('Trash'), hasLength(1));
    final trashed = await list('Trash');
    expect(trashed.single.id, id);

    await gateway.mailAction(id, 'restore');
    expect(await onServer('INBOX'), hasLength(1));
    expect((await list('Inbox')).single.id, id);

    await gateway.mailAction(id, 'archive');
    expect(await onServer('Archive'), hasLength(1));
    expect((await list('Archive')).single.id, id);
  });

  check('permanent delete removes it from the server', () async {
    await gateway.sendMail(
      to: [self],
      subject: 'Silinecek',
      idempotencyKey: 'k1',
    );
    final id = (await list('Inbox')).single.id;
    final results = await gateway.bulkAction('delete', [id]);
    expect(results.single.success, isTrue);
    expect(await onServer('INBOX'), isEmpty);
  });

  check('folders: create, rename, file mail in, delete', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final first = await gateway.createFolder('Projeler $stamp');
    final second = await gateway.createFolder('Arsiv $stamp');
    final child = await gateway.createFolder('Alt', parentId: first.id);
    expect(child.fullName, endsWith('Alt'));
    expect(child.parentId, first.id);

    final renamed = await gateway.renameFolder(child.id, 'Alt 2');
    expect(renamed.id, child.id);
    expect(renamed.name, 'Alt 2');
    expect(renamed.parentId, first.id);

    // Mail put in the renamed folder stays with it.
    await gateway.sendMail(
      to: [self],
      subject: 'Klasörlü',
      idempotencyKey: 'k1',
    );
    final id = (await list('Inbox')).single.id;
    await gateway.moveMail(id, child.id);
    expect((await list(renamed.fullName)).single.id, id);

    await gateway.mailAction(id, 'delete');
    for (final folder in [child, first, second]) {
      await gateway.deleteFolder(folder.id);
    }
    final left = await gateway.getFolders();
    expect(
      left.where((f) => {first.id, second.id, child.id}.contains(f.id)),
      isEmpty,
    );
  });

  check('drafts: save, change, send', () async {
    final draft = await gateway.createDraft(
      to: [self],
      bcc: ['gizli@example.net'],
      subject: 'Taslak v1',
      bodyText: 'ilk hâli',
    );
    expect(draft.mailId, isNotNull);
    final updated = await gateway.updateDraft(
      draft.mailId!,
      to: [self],
      subject: 'Taslak v2',
      bodyText: 'ikinci hâli',
    );
    expect(updated.mailId, isNot(draft.mailId));
    expect(await onServer('Drafts'), hasLength(1));

    final sent = await gateway.sendDraft(updated.mailId!, idempotencyKey: 'k1');
    expect(sent.sent, isTrue);
    expect(sent.draftRemoved, isTrue);
    expect(await onServer('Drafts'), isEmpty);
    expect((await list('Inbox')).single.subject, 'Taslak v2');
  });

  check('an attachment survives the trip byte for byte', () async {
    final bytes = Uint8List.fromList(
      List.generate(40000, (i) => (i * 7) % 256),
    );
    await gateway.sendMail(
      to: [self],
      subject: 'Ekli',
      bodyText: 'ekte dosya var',
      attachments: [
        Attachment(
          name: 'rapor şubat.bin',
          sizeBytes: bytes.length,
          bytes: bytes,
          mimeType: 'application/octet-stream',
        ),
      ],
      idempotencyKey: 'k1',
    );
    final id = (await list('Inbox')).single.id;
    final mail = await gateway.getMail(id, resolveFolder: resolve);
    expect(mail.attachments.single.name, 'rapor şubat.bin');
    final downloaded = await gateway.downloadAttachment(
      id,
      mail.attachments.single.id!,
    );
    expect(downloaded, bytes);
  });

  check('searching the server brings in what the device lacks', () async {
    for (var i = 0; i < 4; i++) {
      await gateway.sendMail(
        to: [self],
        subject: 'Mektup $i',
        bodyText: i == 1 ? 'nadirkelime burada' : 'sıradan',
        idempotencyKey: 'k$i',
      );
    }
    await list('Inbox', count: 4);
    final inbox = await folderId('Inbox');
    final result = await gateway.searchRemote(
      query: 'nadirkelime',
      folderId: inbox,
    );
    expect(result.matched, 1);
    final found = await gateway.search(
      query: 'nadirkelime',
      resolveFolder: resolve,
    );
    expect(found.items.single.subject, 'Mektup 1');
  });

  check('a scheduled send goes out when it is due', () async {
    final item = await gateway.scheduleSend(
      to: [self],
      subject: 'Zamanlı',
      bodyText: 'sonra',
      sendAtUtc: DateTime.now().add(const Duration(seconds: 1)),
      idempotencyKey: 's1',
    );
    expect(await gateway.runDueScheduledSends(), 0);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(await gateway.runDueScheduledSends(), 1);
    expect((await list('Inbox')).single.subject, 'Zamanlı');
    expect((await gateway.listScheduledSends()).single.id, item.id);
  });

  check('watching the inbox announces mail that arrives', () async {
    await gateway.sendMail(to: [self], subject: 'İlk', idempotencyKey: 'k0');
    await list('Inbox');
    final events = <GatewayEvent>[];
    final sub = gateway.events.listen(events.add);
    gateway.setForeground(true);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // Another sender delivers while the watch is running.
    final other = EnoughSmtpSender(
      endpoint: DirectEndpoint(
        host: IntegrationEnvironment.host,
        port: IntegrationEnvironment.smtpPort,
        security: MailSecurity.startTls,
        username: IntegrationEnvironment.user,
      ),
      password: IntegrationEnvironment.password,
      clientDomain: 'example.org',
      transport: SmtpTransport.plaintext,
    );
    await other.send(
      MessageComposer.compose(
        const ComposeInput(
          fromAddress: 'ali@example.org',
          to: [self],
          subject: 'Dışarıdan',
          bodyText: 'selam',
        ),
      ),
    );
    for (var i = 0; i < 100 && !events.any((e) => e.incoming.isNotEmpty); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await sub.cancel();
    expect(
      events.expand((e) => e.incoming).map((m) => m.subject),
      contains('Dışarıdan'),
    );
  });
}
