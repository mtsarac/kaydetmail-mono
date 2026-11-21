@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/enough_imap_service.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/imap_service.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/integration_environment.dart';

/// The real IMAP adapter against a real server. Everything the sync engine
/// and the gateway assume about `enough_mail_plus` and about servers is
/// checked here once, so the unit tests can lean on the in-memory double.
void main() {
  final skip = IntegrationEnvironment.skipUnlessGreenMail;

  DirectEndpoint endpoint({String? host, int? port, String? user}) =>
      DirectEndpoint(
        host: host ?? IntegrationEnvironment.host,
        port: port ?? IntegrationEnvironment.imapPort,
        security: MailSecurity.startTls,
        username: user ?? IntegrationEnvironment.user,
      );

  EnoughImapService service({DirectEndpoint? ep, String? password}) =>
      EnoughImapService(
        endpoint: ep ?? endpoint(),
        password: password ?? IntegrationEnvironment.password,
        transport: ImapTransport.plaintext,
        connectTimeout: const Duration(seconds: 5),
        responseTimeout: const Duration(seconds: 15),
      );

  /// A header word as real mail clients write it (RFC 2047).
  String encoded(String text) => text.runes.every((r) => r < 0x80)
      ? text
      : '=?UTF-8?B?${base64.encode(utf8.encode(text))}?=';

  String mail(
    String id, {
    String subject = 'Test',
    String body = 'merhaba',
    String from = 'ayse@example.org',
  }) => [
    'From: $from',
    'To: ${IntegrationEnvironment.user}',
    'Subject: ${encoded(subject)}',
    'Message-ID: <$id@example.org>',
    'Date: Mon, 6 Oct 2025 10:00:00 +0000',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=utf-8',
    'Content-Transfer-Encoding: 8bit',
    '',
    body,
    '',
  ].join('\r\n');

  /// Folder names must not collide across runs on a server that is reused.
  String unique(String base) =>
      '$base ${DateTime.now().microsecondsSinceEpoch}';

  late EnoughImapService imap;

  /// Starts every test from empty folders. Folders themselves stay (tests that
  /// need one use their own names): GreenMail drops connections around folder
  /// deletion, so nothing else depends on it.
  Future<void> clean() async {
    final cleaner = service();
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
    imap = service();
    await imap.connect();
  });

  tearDown(() async {
    if (IntegrationEnvironment.greenMailEnabled) await imap.disconnect();
  });

  group('connection', () {
    test('signs in and reads capabilities', () {
      expect(imap.isConnected, isTrue);
      expect(imap.capabilities.idle, isTrue);
      expect(imap.capabilities.uidPlus, isTrue);
      expect(imap.capabilities.move, isTrue);
    }, skip: skip);

    test(
      'a wrong password is an authentication failure, not a generic one',
      () async {
        final bad = service(password: 'nope');
        await expectLater(
          bad.connect(),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.kind,
              'kind',
              DirectErrorKind.authFailed,
            ),
          ),
        );
        expect(bad.isConnected, isFalse);
      },
      skip: skip,
    );

    test('an unknown user is an authentication failure too', () async {
      final bad = service(ep: endpoint(user: 'nobody@localhost'));
      await expectLater(
        bad.connect(),
        throwsA(
          isA<DirectMailException>().having(
            (e) => e.kind,
            'kind',
            DirectErrorKind.authFailed,
          ),
        ),
      );
    }, skip: skip);

    test('a closed port is told apart from a missing host name', () async {
      await expectLater(
        service(ep: endpoint(port: 1)).connect(),
        throwsA(
          isA<DirectMailException>().having(
            (e) => e.kind,
            'kind',
            DirectErrorKind.hostUnreachable,
          ),
        ),
      );
      await expectLater(
        service(ep: endpoint(host: 'no-such-host.invalid')).connect(),
        throwsA(
          isA<DirectMailException>().having(
            (e) => e.kind,
            'kind',
            DirectErrorKind.dnsFailure,
          ),
        ),
      );
    }, skip: skip);

    test(
      'disconnect is safe to repeat, and commands afterwards say offline',
      () async {
        await imap.disconnect();
        await imap.disconnect();
        expect(imap.isConnected, isFalse);
        await expectLater(
          imap.listFolders(),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.kind,
              'kind',
              DirectErrorKind.offline,
            ),
          ),
        );
      },
      skip: skip,
    );
  });

  group('reading', () {
    test('lists INBOX with its role', () async {
      final folders = await imap.listFolders();
      final inbox = folders.firstWhere((f) => f.path == 'INBOX');
      expect(inbox.specialUse, FolderRole.inbox);
      expect(inbox.selectable, isTrue);
    }, skip: skip);

    test('append, then read back headers, flags, date and full body', () async {
      final result = await imap.append(
        'INBOX',
        mail('a1', subject: 'Türkçe konu şğüıöç', body: 'Merhaba İĞŞ şğüıöç'),
        flags: {r'\Seen'},
      );
      expect(result.uid, isNotNull);
      final uid = result.uid!;

      final state = await imap.select('INBOX');
      expect(state.exists, 1);
      expect(state.uidNext, greaterThan(uid));
      expect(state.uidValidity, greaterThan(0));

      final headers = await imap.fetchHeaders('INBOX', [uid]);
      expect(headers.single.uid, uid);
      expect(headers.single.flags, contains(r'\Seen'));
      expect(headers.single.internalDate, isNotNull);
      expect(headers.single.mime!.decodeSubject(), 'Türkçe konu şğüıöç');

      final full = await imap.fetchFull('INBOX', uid);
      expect(full.mime!.decodeTextPlainPart()!.trim(), 'Merhaba İĞŞ şğüıöç');
    }, skip: skip);

    test('UID ranges never return a message below the range', () async {
      final a = (await imap.append('INBOX', mail('r1'))).uid!;
      final b = (await imap.append('INBOX', mail('r2'))).uid!;
      expect(await imap.listUids('INBOX'), [a, b]);
      expect(await imap.listUids('INBOX', fromUid: b), [b]);
      expect(await imap.listUids('INBOX', fromUid: b + 100), isEmpty);
      expect(await imap.listUids('INBOX', fromUid: 1, toUid: a), [a]);
    }, skip: skip);

    test('flags can be read, set and cleared by UID', () async {
      final uid = (await imap.append('INBOX', mail('f1'))).uid!;
      await imap.storeFlags(
        'INBOX',
        [uid],
        add: {r'\Seen', r'\Flagged', r'$Forwarded'},
      );
      var flags = (await imap.fetchFlags('INBOX', fromUid: uid)).single.flags;
      expect(flags, containsAll([r'\Seen', r'\Flagged', r'$Forwarded']));
      await imap.storeFlags('INBOX', [uid], remove: {r'\Seen'});
      flags = (await imap.fetchFlags('INBOX', fromUid: uid)).single.flags;
      expect(flags, isNot(contains(r'\Seen')));
      expect(flags, contains(r'\Flagged'));
    }, skip: skip);

    test('status reports the unread count', () async {
      await imap.append('INBOX', mail('s1'));
      await imap.append('INBOX', mail('s2'), flags: {r'\Seen'});
      final state = await imap.status('INBOX');
      expect(state.exists, 2);
      expect(state.unseen, 1);
    }, skip: skip);
  });

  group('changing', () {
    test('Turkish folder names are created, listed and selected', () async {
      final name = unique('Arşiv Ğ');
      await imap.createFolder(name);
      expect((await imap.listFolders()).map((f) => f.path), contains(name));
      expect((await imap.select(name)).exists, 0);
      await imap.append(name, mail('t1', subject: 'Arşivlenmiş'));
      expect(await imap.listUids(name), hasLength(1));
    }, skip: skip);

    test('Turkish folder names are created, listed and selected', () async {
      final name = unique('Arşiv Ğ');
      await imap.createFolder(name);
      expect((await imap.listFolders()).map((f) => f.path), contains(name));
      final state = await imap.select(name);
      expect(state.exists, 0);
      await imap.append(name, mail('t1', subject: 'Arşivlenmiş'));
      expect(await imap.listUids(name), hasLength(1));
    }, skip: skip);

    test('a folder can be renamed and removed', () async {
      // GreenMail keeps listening for folders a closed session had selected
      // and then fails their deletion, so this folder is never selected.
      final name = unique('Geçici');
      final renamed = unique('Yeni Ad');
      await imap.createFolder(name);
      await imap.renameFolder(name, renamed);
      final names = (await imap.listFolders()).map((f) => f.path);
      expect(names, contains(renamed));
      expect(names, isNot(contains(name)));
      await imap.deleteFolder(renamed);
      expect(
        (await imap.listFolders()).map((f) => f.path),
        isNot(contains(renamed)),
      );
    }, skip: skip);

    test('copy and move report where the message went', () async {
      final target = unique('Hedef');
      await imap.createFolder(target);
      final uid = (await imap.append(
        'INBOX',
        mail('c1', subject: 'kopya'),
      )).uid!;

      final copied = await imap.copy('INBOX', [uid], target);
      expect(copied.targetFor(uid), isNotNull);
      expect(await imap.listUids('INBOX'), [uid]);

      final moved = await imap.move('INBOX', [uid], target);
      expect(moved.targetFor(uid), isNotNull);
      expect(await imap.listUids('INBOX'), isEmpty);
      expect(await imap.listUids(target), hasLength(2));
    }, skip: skip);

    test('expunge removes exactly the given messages', () async {
      final a = (await imap.append('INBOX', mail('e1'))).uid!;
      final b = (await imap.append('INBOX', mail('e2'))).uid!;
      final c = (await imap.append('INBOX', mail('e3'))).uid!;
      await imap.expunge('INBOX', [b]);
      expect(await imap.listUids('INBOX'), [a, c]);
    }, skip: skip);

    test('selecting a folder that does not exist is a folder error', () async {
      await expectLater(
        imap.select('Yok Boyle Klasor'),
        throwsA(
          isA<DirectMailException>().having(
            (e) => e.kind,
            'kind',
            DirectErrorKind.folderNotFound,
          ),
        ),
      );
      // The connection is still usable afterwards.
      expect((await imap.select('INBOX')).exists, 0);
    }, skip: skip);
  });

  group('search', () {
    test('finds by text, sender and read state', () async {
      final a = (await imap.append(
        'INBOX',
        mail('q1', subject: 'Fatura Ocak', from: 'muhasebe@example.org'),
      )).uid!;
      await imap.append(
        'INBOX',
        mail('q2', subject: 'Toplanti', from: 'ayse@example.org'),
        flags: {r'\Seen'},
      );
      expect(
        await imap.search('INBOX', const RemoteSearchQuery(text: 'Fatura')),
        [a],
      );
      expect(
        await imap.search(
          'INBOX',
          const RemoteSearchQuery(from: 'muhasebe@example.org'),
        ),
        [a],
      );
      expect(
        await imap.search('INBOX', const RemoteSearchQuery(unseen: true)),
        [a],
      );
      expect(
        await imap.search('INBOX', const RemoteSearchQuery()),
        hasLength(2),
      );
    }, skip: skip);

    test(
      'non-ASCII terms are refused rather than sent as the wrong bytes',
      () async {
        await expectLater(
          imap.search('INBOX', const RemoteSearchQuery(text: 'şğü')),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.kind,
              'kind',
              DirectErrorKind.capabilityMissing,
            ),
          ),
        );
      },
      skip: skip,
    );
  });

  group('push', () {
    test('a message delivered while idling is announced', () async {
      final pushed = Completer<ImapPush>();
      final sub = imap.idle('INBOX').listen((p) {
        if (!pushed.isCompleted) pushed.complete(p);
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final other = service();
      await other.connect();
      await other.append('INBOX', mail('p1'));
      await other.disconnect();

      expect(
        await pushed.future.timeout(const Duration(seconds: 15)),
        ImapPush.newMail,
      );
      await sub.cancel();
    }, skip: skip);
  });

  group('sync engine on a real server', () {
    test('first sync, new mail, flags and deletion', () async {
      final store = DirectStore(sqlite3.openInMemory());
      final engine = SyncEngine(
        store: store,
        imap: imap,
        accountId: 'acc',
        ownAddress: IntegrationEnvironment.user,
        options: const SyncOptions(prefetchBodies: 5),
      );
      final a = (await imap.append(
        'INBOX',
        mail('g1', subject: 'Bir', body: 'ilk mesaj'),
      )).uid!;
      final b = (await imap.append(
        'INBOX',
        mail('g2', subject: 'İki', body: 'ikinci'),
      )).uid!;

      await engine.syncFolderList();
      final inbox = store.folderByRole('acc', FolderRole.inbox)!;
      final first = await engine.syncFolder(inbox.folderId);
      expect(store.uids('acc', inbox.folderId), [a, b]);
      expect(first.newLocalIds, hasLength(2));
      expect(
        store.messageByUid('acc', inbox.folderId, a)!.snippet,
        'ilk mesaj',
      );
      expect(store.messageByUid('acc', inbox.folderId, b)!.subject, 'İki');

      final c = (await imap.append('INBOX', mail('g3', subject: 'Üç'))).uid!;
      await imap.storeFlags('INBOX', [a], add: {r'\Seen'});
      await imap.expunge('INBOX', [b]);
      final second = await engine.syncFolder(inbox.folderId);

      expect(store.uids('acc', inbox.folderId), [a, c]);
      expect(second.removed, 1);
      expect(second.flagChanges, 1);
      expect(store.messageByUid('acc', inbox.folderId, a)!.isRead, isTrue);
      expect(store.folder('acc', inbox.folderId)!.remoteUnseen, 1);
    }, skip: skip);
  });
}
