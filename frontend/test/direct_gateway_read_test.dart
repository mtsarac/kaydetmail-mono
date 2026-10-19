import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';

import 'support/direct_rig.dart';
import 'support/mime_fixtures.dart';

MailFolder _resolve(String id) => MailFolder.inbox;

DirectMailException _offline() =>
    DirectMailException(DirectErrorKind.hostUnreachable);

void main() {
  late DirectRig rig;

  tearDown(() => rig.dispose());

  group('folders', () {
    test('the first call reads the server and lists the folders', () async {
      rig = DirectRig();
      rig.imap.addFolder('Sent', use: FolderRole.sent);
      rig.imap.addFolder('Projeler/Raporlar');
      final folders = await rig.gateway.getFolders();
      expect(
        folders.map((f) => f.type),
        containsAll(['Inbox', 'Sent', 'Custom']),
      );
      final inbox = folders.firstWhere((f) => f.type == 'Inbox');
      expect(inbox.mailAccountId, rigAccountId);
      expect(inbox.isSyncEnabled, isTrue);
      expect(
        folders
            .firstWhere((f) => f.fullName == 'Projeler/Raporlar')
            .isSyncEnabled,
        isFalse,
      );
    });

    test('later calls answer from the store without the server', () async {
      rig = DirectRig();
      await rig.gateway.getFolders();
      rig.imap.resetCalls();
      await rig.gateway.getFolders();
      expect(rig.imap.count('connect'), 0);
      expect(rig.imap.count('listFolders'), 0);
    });

    test(
      'an unreachable server is reported even with folders stored',
      () async {
        rig = DirectRig();
        await rig.gateway.getFolders();
        final events = <GatewayEventKind>[];
        rig.gateway.events.listen((e) => events.add(e.kind));
        // A sync fails and the gateway notes the server as unreachable.
        final inbox = await rig.inboxId();
        await rig.runtime.connection
            .credentialsChanged(); // drop the connection
        rig.imap.failNext('connect', _offline());
        await expectLater(
          rig.gateway.syncFolderId(inbox),
          throwsA(isA<DirectMailException>()),
        );
        await expectLater(
          rig.gateway.getFolders(),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.category,
              'category',
              ApiErrorCategory.network,
            ),
          ),
        );
        // Waiting out the back-off, the server answers again.
        rig.clock.advance(const Duration(hours: 1));
        expect(await rig.gateway.getFolders(), isNotEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(events, [GatewayEventKind.offline, GatewayEventKind.online]);
      },
    );

    test('nested folders point at their parent', () async {
      rig = DirectRig();
      rig.imap
        ..addFolder('Projeler')
        ..addFolder('Projeler/2025');
      final folders = await rig.gateway.getFolders();
      final parent = folders.firstWhere((f) => f.fullName == 'Projeler');
      final child = folders.firstWhere((f) => f.fullName == 'Projeler/2025');
      expect(child.parentId, parent.id);
      expect(parent.parentId, isNull);
      expect(child.name, '2025');
    });
  });

  group('mail list', () {
    test(
      'opening a folder the first time syncs it and lists newest first',
      () async {
        rig = DirectRig();
        for (var i = 1; i <= 3; i++) {
          rig.imap.add('INBOX', rigMail('m$i', subject: 'Konu $i'));
        }
        final inbox = await rig.inboxId();
        final page = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
        );
        expect(page.items.map((e) => e.subject), [
          'Konu 3',
          'Konu 2',
          'Konu 1',
        ]);
        expect(page.total, 3);
        expect(page.items.first.accountId, rigAccountId);
        expect(page.items.first.id, startsWith('d:'));
      },
    );

    test('a fresh folder is answered from the store alone', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('m1'));
      final inbox = await rig.inboxId();
      await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
      rig.imap.resetCalls();
      rig.clock.advance(const Duration(seconds: 5));
      final page = await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      );
      expect(page.items, hasLength(1));
      expect(rig.imap.count('connect'), 0);
      expect(rig.imap.count('select'), 0);
    });

    test(
      'an old folder answers at once and syncs behind, then says so',
      () async {
        rig = DirectRig();
        rig.imap.add('INBOX', rigMail('m1'));
        final inbox = await rig.inboxId();
        await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
        rig.imap.add('INBOX', rigMail('m2', subject: 'Yeni'));
        rig.clock.advance(const Duration(minutes: 5));

        final changed = Completer<GatewayEvent>();
        rig.gateway.events.listen((e) {
          if (e.kind == GatewayEventKind.mail) changed.complete(e);
        });
        final page = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
        );
        expect(page.items, hasLength(1), reason: 'stored mail first');
        final event = await changed.future.timeout(const Duration(seconds: 5));
        expect(event.folderId, inbox);
        expect(event.newMailIds, hasLength(1));
        final again = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
        );
        expect(again.items.first.subject, 'Yeni');
      },
    );

    test('offline with mail stored still lists it', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('m1'));
      final inbox = await rig.inboxId();
      await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
      rig.clock.advance(const Duration(minutes: 5));
      await rig.runtime.connection.credentialsChanged();
      rig.imap.failNext('connect', _offline(), times: 5);
      final page = await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      );
      expect(page.items, hasLength(1));
    });

    test(
      'offline with nothing stored is an error, not an empty folder',
      () async {
        rig = DirectRig();
        final inbox = await rig.inboxId();
        await rig.runtime.connection.credentialsChanged();
        rig.imap.failNext('connect', _offline());
        await expectLater(
          rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve),
          throwsA(isA<DirectMailException>()),
        );
      },
    );

    test('scrolling past the stored window fetches older mail', () async {
      rig = DirectRig(
        options: const SyncOptions(initialWindow: 10, prefetchBodies: 0),
      );
      for (var i = 1; i <= 25; i++) {
        rig.imap.add('INBOX', rigMail('m$i', subject: 'Konu $i'));
      }
      final inbox = await rig.inboxId();
      final first = await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
        pageSize: 5,
      );
      expect(first.total, 25, reason: 'the server count, not the window');
      expect(first.items.first.subject, 'Konu 25');

      final third = await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
        page: 3,
        pageSize: 5,
      );
      expect(third.items.map((e) => e.subject).first, 'Konu 15');
      final last = await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
        page: 5,
        pageSize: 5,
      );
      expect(last.items.last.subject, 'Konu 1');
      expect(last.total, 25);
    });

    test('the list cannot run dry while offline', () async {
      rig = DirectRig(
        options: const SyncOptions(initialWindow: 5, prefetchBodies: 0),
      );
      for (var i = 1; i <= 12; i++) {
        rig.imap.add('INBOX', rigMail('m$i'));
      }
      final inbox = await rig.inboxId();
      await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
        pageSize: 5,
      );
      await rig.runtime.connection.credentialsChanged();
      rig.imap.failNext('connect', _offline(), times: 5);
      await expectLater(
        rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
          page: 2,
          pageSize: 5,
        ),
        throwsA(isA<DirectMailException>()),
      );
    });

    test(
      'unread and attachment filters and text search work on stored mail',
      () async {
        rig = DirectRig();
        rig.imap.add(
          'INBOX',
          rigMail('a', subject: 'Fatura'),
          flags: {r'\Seen'},
        );
        rig.imap.add('INBOX', rigMail('b', subject: 'Toplantı notları'));
        final inbox = await rig.inboxId();
        final unread = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
          isRead: false,
        );
        expect(unread.items.map((e) => e.subject), ['Toplantı notları']);
        final found = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
          search: 'fatura',
        );
        expect(found.items.map((e) => e.subject), ['Fatura']);
        expect(found.total, 1);
        final percent = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
          search: '100%',
        );
        expect(percent.items, isEmpty, reason: 'LIKE wildcards are literal');
      },
    );

    test(
      'folder unread counts come from the server while older mail is missing',
      () async {
        rig = DirectRig(
          options: const SyncOptions(initialWindow: 5, prefetchBodies: 0),
        );
        for (var i = 1; i <= 12; i++) {
          rig.imap.add('INBOX', rigMail('m$i'));
        }
        final inbox = await rig.inboxId();
        await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
        final folder = (await rig.gateway.getFolders()).firstWhere(
          (f) => f.id == inbox,
        );
        expect(folder.unreadCount, 12);
        expect(folder.totalCount, 12);
      },
    );
  });

  group('one mail', () {
    test('the body is fetched on first open and kept for offline', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('m1', body: 'gövde metni'));
      final inbox = await rig.inboxId();
      final id = (await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      )).items.single.id;
      rig.imap.resetCalls();
      final first = await rig.gateway.getMail(id, resolveFolder: _resolve);
      expect(first.bodyText, contains('gövde metni'));
      expect(rig.imap.count('fetchFull'), 1);
      rig.imap.resetCalls();
      await rig.runtime.connection.credentialsChanged();
      rig.imap.failNext('connect', _offline(), times: 3);
      final second = await rig.gateway.getMail(id, resolveFolder: _resolve);
      expect(second.bodyText, contains('gövde metni'));
      expect(rig.imap.count('fetchFull'), 0);
    });

    test('an unknown id is mail_not_found', () async {
      rig = DirectRig();
      await expectLater(
        rig.gateway.getMail('d:nope', resolveFolder: _resolve),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'mail_not_found'),
        ),
      );
    });

    test(
      'a mail gone from the server is mail_not_found and gets cleaned up',
      () async {
        rig = DirectRig();
        final uid = rig.imap.add('INBOX', rigMail('m1'));
        final inbox = await rig.inboxId();
        final id = (await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
        )).items.single.id;
        rig.imap.remove('INBOX', uid);
        await expectLater(
          rig.gateway.getMail(id, resolveFolder: _resolve),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'mail_not_found'),
          ),
        );
        // The pass started by the failed open drops the stored row.
        for (
          var i = 0;
          i < 50 && rig.store.message(rigAccountId, id) != null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(rig.store.message(rigAccountId, id), isNull);
      },
    );

    test('remote images stay blocked until asked for', () async {
      rig = DirectRig();
      rig.imap.add(
        'INBOX',
        [
          'From: a@example.org',
          'To: $rigAddress',
          'Subject: Resimli',
          'Message-ID: <img@example.org>',
          'Date: Mon, 6 Oct 2025 10:00:00 +0000',
          'MIME-Version: 1.0',
          'Content-Type: text/html; charset=utf-8',
          '',
          '<p>merhaba</p><img src="https://images.example/a.png" width="300">',
          '',
        ].join('\r\n'),
      );
      final inbox = await rig.inboxId();
      final id = (await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      )).items.single.id;
      final blocked = await rig.gateway.getMail(id, resolveFolder: _resolve);
      expect(blocked.hasRemoteContent, isTrue);
      expect(blocked.bodyHtml, isNot(contains(' src="https://images.example')));
      expect(blocked.remoteImagesAllowed, isFalse);
      final allowed = await rig.gateway.getMail(
        id,
        resolveFolder: _resolve,
        allowRemoteImages: true,
      );
      expect(allowed.bodyHtml, contains('src="https://images.example/a.png"'));
      expect(allowed.remoteImagesAllowed, isTrue);
    });

    test('headers, source and attachments come from the server copy', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', turkishMail);
      final inbox = await rig.inboxId();
      final id = (await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      )).items.single.id;
      final mail = await rig.gateway.getMail(id, resolveFolder: _resolve);
      expect(mail.attachments, isNotEmpty);
      final pdf = mail.attachments.firstWhere((a) => a.name.endsWith('.pdf'));
      expect(pdf.name, 'rapor şubat.pdf');

      final headers = await rig.gateway.getMailHeaders(id);
      expect(
        headers.map((h) => h.name.toLowerCase()),
        containsAll(['from', 'subject', 'message-id']),
      );
      final source = await rig.gateway.getMailSource(id);
      expect(source, contains('Message-ID: <abc.123@example.test>'));

      final bytes = await rig.gateway.downloadAttachment(id, pdf.id!);
      expect(bytes, isNotEmpty);
      await expectLater(
        rig.gateway.downloadAttachment(id, '99'),
        throwsA(isA<ApiException>()),
      );
    });

    test('signatures are shown but reported as not verifiable', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('m1'));
      final inbox = await rig.inboxId();
      final id = (await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      )).items.single.id;
      final result = await rig.gateway.getMailSignature(id);
      expect(result.status, 'Unverifiable');
      expect(result.signers, isEmpty);
    });
  });

  group('conversations', () {
    test('replies share a conversation, listed with counts', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a', subject: 'Plan'));
      rig.imap.add(
        'INBOX',
        rigMail(
          'b',
          subject: 'Re: Plan',
          inReplyTo: 'a',
          references: '<a@example.org>',
        ),
      );
      rig.imap.add('INBOX', rigMail('c', subject: 'Başka'), flags: {r'\Seen'});
      final inbox = await rig.inboxId();
      await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);

      final list = await rig.gateway.getConversations();
      expect(list.total, 2);
      final plan = list.items.firstWhere((c) => c.messageCount == 2);
      expect(plan.unreadCount, 2);

      final conversation = await rig.gateway.getConversation(plan.id);
      expect(conversation.messageIds, hasLength(2));

      final withBodies = await rig.gateway.getConversationWithBodies(plan.id);
      final mails = [
        for (final m in withBodies.messages)
          rig.gateway.mapConversationMessage(m, _resolve),
      ];
      expect(mails.map((m) => m.bodyText), everyElement(contains('merhaba')));
      expect(mails.every((m) => m.threadId == plan.id), isTrue);
    });

    test(
      'a conversation opens offline with the bodies that are stored',
      () async {
        rig = DirectRig();
        rig.imap.add('INBOX', rigMail('a', subject: 'Plan'));
        final inbox = await rig.inboxId();
        await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
        final id = (await rig.gateway.getConversations()).items.single.id;
        await rig.runtime.connection.credentialsChanged();
        rig.imap.failNext('connect', _offline(), times: 3);
        final result = await rig.gateway.getConversationWithBodies(id);
        expect(result.messageIds, hasLength(1));
      },
    );
  });

  group('account', () {
    test('describes itself as a direct account', () async {
      rig = DirectRig();
      final account = await rig.gateway.getAccount();
      expect(account.isDirect, isTrue);
      expect(account.email, rigAddress);
      expect(account.displayName, 'Ben');
    });

    test('the signature is kept on the device', () async {
      rig = DirectRig();
      await rig.gateway.updateSignature('  Saygılarımla  ');
      expect((await rig.gateway.getAccount()).signature, 'Saygılarımla');
      await rig.gateway.updateSignature('');
      expect((await rig.gateway.getAccount()).signature, isNull);
    });

    test('sync scope follows the folder flags', () async {
      rig = DirectRig();
      rig.imap.addFolder('Sent', use: FolderRole.sent);
      rig.imap.addFolder('Arşiv', use: FolderRole.archive);
      await rig.gateway.getFolders();
      expect((await rig.gateway.getSyncScope()).scope, 'InboxAndSent');
      final all = await rig.gateway.updateSyncScope('AllFolders');
      expect(all.scope, 'AllFolders');
      final folders = await rig.gateway.getFolders();
      final archive = folders.firstWhere((f) => f.type == 'Archive');
      final chosen = await rig.gateway.updateSyncScope(
        'SelectedFolders',
        folderIds: [archive.id],
      );
      expect(chosen.scope, 'SelectedFolders');
      expect(chosen.syncedFolderIds, {archive.id});
    });

    test(
      'notification settings default to full previews and persist',
      () async {
        rig = DirectRig();
        final defaults = await rig.gateway.getNotificationSettings();
        expect(defaults.enabled, isTrue);
        final saved = await rig.gateway.updateNotificationSettings(
          defaults.copyWith(enabled: false),
        );
        expect(saved.enabled, isFalse);
        expect((await rig.gateway.getNotificationSettings()).enabled, isFalse);
      },
    );

    test(
      'a refused password locks the account until a new one works',
      () async {
        rig = DirectRig();
        await rig.gateway.getFolders();
        await rig.runtime.connection.credentialsChanged();
        rig.imap.failNext(
          'connect',
          DirectMailException(DirectErrorKind.authFailed),
        );
        final inbox = await rig.inboxId();
        await expectLater(
          rig.gateway.syncFolderId(inbox),
          throwsA(isA<DirectMailException>()),
        );
        expect(
          (await rig.gateway.getAccount()).status.name,
          'needsReauthentication',
        );
        rig.imap.resetCalls();
        await expectLater(
          rig.gateway.syncFolderId(inbox),
          throwsA(isA<DirectMailException>()),
        );
        expect(rig.imap.count('connect'), 0, reason: 'no second attempt');

        final account = await rig.gateway.reconnect(password: 'yeni');
        expect(account.status.name, 'active');
        expect(rig.runtime.credentials.imapPassword, 'yeni');
      },
    );

    test('deleting the account removes its mail from the device', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('m1'));
      final inbox = await rig.inboxId();
      await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
      var deleted = false;
      rig.runtime.onDeleted = () async => deleted = true;
      await rig.gateway.deleteAccount();
      expect(rig.store.folders(rigAccountId), isEmpty);
      expect(rig.store.count(rigAccountId, inbox), 0);
      expect(deleted, isTrue);
    });
  });
}
