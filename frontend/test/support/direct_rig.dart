import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/connection_policy.dart';
import 'package:kaydetmail/services/direct/direct_account_runtime.dart';
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_credential_store.dart';
import 'package:kaydetmail/services/direct/direct_mail_gateway.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_imap_service.dart';
import 'fake_smtp_sender.dart';

const rigAccountId = 'acc';
const rigAddress = 'me@example.com';

/// A wall clock tests move by hand; the store, the connection policy and the
/// gateway all read it, so "30 seconds later" means the same to each.
class TestClock {
  TestClock([DateTime? start]) : now = start ?? DateTime.utc(2025, 10, 6, 12);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

MailFolder resolveFolderForTests(String id) => MailFolder.inbox;

/// A direct account over an in-memory server: the real gateway, store and
/// connection, with [FakeImapService] standing in for the wire.
class DirectRig {
  DirectRig({
    SyncOptions options = const SyncOptions(prefetchBodies: 0),
    Duration staleAfter = const Duration(seconds: 30),
    Set<String>? capabilities,
    bool addInbox = true,
    String namespacePrefix = '',
    String delimiter = '/',
    String smtpHost = 'smtp.example.com',
    bool saveSentCopy = true,
  }) : clock = TestClock() {
    imap = capabilities == null
        ? FakeImapService(
            namespacePrefix: namespacePrefix,
            delimiter: delimiter,
          )
        : FakeImapService(
            capabilities: capabilities,
            namespacePrefix: namespacePrefix,
            delimiter: delimiter,
          );
    if (addInbox) imap.addFolder('INBOX', use: FolderRole.inbox);
    store = DirectStore(sqlite3.openInMemory(), clock: clock.call);
    runtime = DirectAccountRuntime(
      config: DirectAccountConfig(
        id: rigAccountId,
        email: rigAddress,
        displayName: 'Ben',
        imap: DirectEndpoint(
          host: 'imap.example.com',
          port: 993,
          security: MailSecurity.sslOnConnect,
          username: rigAddress,
        ),
        saveSentCopy: saveSentCopy,
        smtp: DirectEndpoint(
          host: smtpHost,
          port: 465,
          security: MailSecurity.sslOnConnect,
          username: rigAddress,
        ),
      ),
      credentials: const DirectCredentials(imapPassword: 'secret'),
      imapFactory: (_, _) => imap,
      smtpFactory: (_, _, _) => smtp,
      policy: ConnectionPolicy(clock: clock.call),
    );
    gateway = DirectMailGateway(
      runtime: runtime,
      store: store,
      syncOptions: options,
      staleAfter: staleAfter,
      clock: clock.call,
    );
  }

  final TestClock clock;
  late final FakeImapService imap;
  final FakeSmtpSender smtp = FakeSmtpSender();
  late final DirectStore store;
  late final DirectAccountRuntime runtime;
  late final DirectMailGateway gateway;

  /// The id the gateway gave the Inbox.
  Future<String> inboxId() async {
    final folders = await gateway.getFolders();
    return folders.firstWhere((f) => f.type == 'Inbox').id;
  }

  Future<void> dispose() => gateway.dispose();
}

/// A plain text mail with the given Message-ID.
String rigMail(
  String id, {
  String subject = 'Konu',
  String from = 'ayse@example.org',
  String to = rigAddress,
  String? inReplyTo,
  String? references,
  String body = 'merhaba',
  String? extra,
}) => [
  'From: $from',
  'To: $to',
  'Subject: $subject',
  'Message-ID: <$id@example.org>',
  'Date: Mon, 6 Oct 2025 10:00:00 +0000',
  if (inReplyTo != null) 'In-Reply-To: <$inReplyTo@example.org>',
  if (references != null) 'References: $references',
  ?extra,
  'MIME-Version: 1.0',
  'Content-Type: text/plain; charset=utf-8',
  '',
  body,
  '',
].join('\r\n');
