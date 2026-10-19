import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';

import 'support/direct_rig.dart';

MailFolder _resolve(String id) => MailFolder.inbox;

DirectMailException _offline() =>
    DirectMailException(DirectErrorKind.hostUnreachable);

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  /// Opens [folder] so its mail is stored, returning the ids newest first.
  Future<List<String>> open(String folder) async {
    final id = (await rig.gateway.getFolders()).firstWhere(
      (f) => f.id == folder || f.fullName == folder || f.type == folder,
    );
    final page = await rig.gateway.getMails(
      folderId: id.id,
      resolveFolder: _resolve,
    );
    return [for (final e in page.items) e.id];
  }

  Future<String> folderId(String typeOrPath) async =>
      (await rig.gateway.getFolders())
          .firstWhere((f) => f.type == typeOrPath || f.fullName == typeOrPath)
          .id;

  Set<String> serverFlags(String path, int uid) =>
      rig.imap.folders[path]!.messages[uid]!.flags;

  group('flags', () {
    test('read and star reach the server, then the store', () async {
      rig = DirectRig();
      final uid = rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      final inbox = await folderId('Inbox');
      expect((await rig.gateway.getFolders()).first.unreadCount, 1);

      final read = await rig.gateway.mailAction(ids.single, 'read');
      expect(read.success, isTrue);
      expect(serverFlags('INBOX', uid), contains(r'\Seen'));
      expect(rig.store.message(rigAccountId, ids.single)!.isRead, isTrue);
      final folder = (await rig.gateway.getFolders()).firstWhere(
        (f) => f.id == inbox,
      );
      expect(folder.unreadCount, 0);

      await rig.gateway.mailAction(ids.single, 'star');
      expect(serverFlags('INBOX', uid), contains(r'\Flagged'));
      await rig.gateway.mailAction(ids.single, 'unread');
      await rig.gateway.mailAction(ids.single, 'unstar');
      expect(serverFlags('INBOX', uid), isEmpty);
      final row = rig.store.message(rigAccountId, ids.single)!;
      expect(row.isRead, isFalse);
      expect(row.isFlagged, isFalse);
      expect((await rig.gateway.getFolders()).first.unreadCount, 1);
    });

    test(
      'marking already-read mail read does not skew the unread count',
      () async {
        rig = DirectRig();
        rig.imap.add('INBOX', rigMail('a'), flags: {r'\Seen'});
        rig.imap.add('INBOX', rigMail('b'));
        final ids = await open('Inbox');
        await rig.gateway.bulkAction('read', ids);
        expect((await rig.gateway.getFolders()).first.unreadCount, 0);
      },
    );

    test(
      'while offline the result is retryable and nothing is claimed',
      () async {
        rig = DirectRig();
        rig.imap.add('INBOX', rigMail('a'));
        final ids = await open('Inbox');
        await rig.runtime.connection.credentialsChanged();
        rig.imap.failNext('connect', _offline(), times: 3);
        final results = await rig.gateway.bulkAction('read', ids);
        expect(results.single.success, isFalse);
        expect(results.single.code, 'network_unavailable');
        expect(results.single.canRetry, isTrue);
        expect(rig.store.message(rigAccountId, ids.single)!.isRead, isFalse);
      },
    );

    test('single actions throw the failure code', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      await rig.runtime.connection.credentialsChanged();
      rig.imap.failNext('connect', _offline());
      await expectLater(
        rig.gateway.mailAction(ids.single, 'read'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'network_unavailable',
          ),
        ),
      );
    });

    test('an unknown action is refused', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      final results = await rig.gateway.bulkAction('explode', ids);
      expect(results.single.success, isFalse);
      expect(results.single.canRetry, isFalse);
    });

    test(
      'a renumbered folder stops the change before it touches anything',
      () async {
        rig = DirectRig();
        rig.imap.add('INBOX', rigMail('a'));
        final ids = await open('Inbox');
        rig.imap.changeUidValidity('INBOX', 999);
        rig.imap.resetCalls();
        final results = await rig.gateway.bulkAction('read', ids);
        expect(results.single.code, 'mailbox_changed');
        expect(results.single.canRetry, isFalse);
        expect(rig.imap.count('storeFlags'), 0);
      },
    );

    test('unknown and not-yet-listed mail are reported one by one', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      final results = await rig.gateway.bulkAction('read', [
        ids.single,
        'd:nope',
      ]);
      expect(results.map((r) => r.success), [true, false]);
      expect(results.last.code, 'mail_not_found');
    });

    test(
      'a lost connection part-way retries the rest without trying again',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Sent', use: FolderRole.sent);
        rig.imap.add('INBOX', rigMail('a'));
        rig.imap.add('Sent', rigMail('b'));
        final inboxIds = await open('Inbox');
        final sentIds = await open('Sent');
        rig.imap.resetCalls();
        rig.imap.failOnNthCall('storeFlags', 2, _offline());
        final results = await rig.gateway.bulkAction('read', [
          ...inboxIds,
          ...sentIds,
        ]);
        expect(results.map((r) => r.success), [true, false]);
        expect(results.last.retryable, isTrue);
        expect(rig.imap.count('storeFlags'), 2);
      },
    );
  });

  group('moving', () {
    test(
      'trash moves the mail, keeps its id, and restore brings it back',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Trash', use: FolderRole.trash);
        final uid = rig.imap.add('INBOX', rigMail('a', subject: 'Silinecek'));
        final ids = await open('Inbox');
        await open('Trash'); // synced before: moves land directly

        final result = await rig.gateway.mailAction(ids.single, 'trash');
        expect(result.success, isTrue);
        expect(result.reconciliationPending, isFalse);
        expect(rig.imap.folders['INBOX']!.messages.containsKey(uid), isFalse);
        expect(rig.imap.folders['Trash']!.messages, hasLength(1));

        final trash = await folderId('Trash');
        final inListing = await rig.gateway.getMails(
          folderId: trash,
          resolveFolder: _resolve,
        );
        expect(inListing.items.single.id, ids.single, reason: 'same local id');
        expect(inListing.items.single.subject, 'Silinecek');
        final inbox = await rig.gateway.getMails(
          folderId: await folderId('Inbox'),
          resolveFolder: _resolve,
        );
        expect(inbox.items, isEmpty);

        final back = await rig.gateway.mailAction(ids.single, 'restore');
        expect(back.success, isTrue);
        expect(rig.imap.folders['INBOX']!.messages, hasLength(1));
        final again = await rig.gateway.getMails(
          folderId: await folderId('Inbox'),
          resolveFolder: _resolve,
        );
        expect(again.items.single.id, ids.single);
      },
    );

    test(
      'a target never opened gets the mail as soon as it is listed',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Archive', use: FolderRole.archive);
        rig.imap.add('INBOX', rigMail('a', subject: 'Arşivlik'));
        final ids = await open('Inbox');
        final result = await rig.gateway.mailAction(ids.single, 'archive');
        expect(result.reconciliationPending, isTrue, reason: 'not listed yet');

        final page = await rig.gateway.getMails(
          folderId: await folderId('Archive'),
          resolveFolder: _resolve,
        );
        expect(page.items.single.id, ids.single);
      },
    );

    test('a server without UIDPLUS is reconciled by Message-ID', () async {
      rig = DirectRig(capabilities: {'IMAP4REV1', 'NAMESPACE', 'UNSELECT'});
      rig.imap.addFolder('Trash', use: FolderRole.trash);
      rig.imap.add('INBOX', rigMail('a', subject: 'Eski sunucu'));
      final ids = await open('Inbox');
      await open('Trash');
      final result = await rig.gateway.mailAction(ids.single, 'trash');
      expect(result.success, isTrue);
      expect(
        result.reconciliationPending,
        isFalse,
        reason: 'listed by the sync that follows',
      );
      final page = await rig.gateway.getMails(
        folderId: await folderId('Trash'),
        resolveFolder: _resolve,
      );
      expect(page.items.single.id, ids.single);
    });

    test('mail that arrived in the target meanwhile is not skipped', () async {
      rig = DirectRig();
      rig.imap.addFolder('Archive', use: FolderRole.archive);
      rig.imap.add('Archive', rigMail('old', subject: 'Eski'));
      rig.imap.add('INBOX', rigMail('a', subject: 'Taşınan'));
      final ids = await open('Inbox');
      await open('Archive');
      rig.imap.add('Archive', rigMail('late', subject: 'Geç geldi'));
      await rig.gateway.mailAction(ids.single, 'archive');
      final page = await rig.gateway.getMails(
        folderId: await folderId('Archive'),
        resolveFolder: _resolve,
      );
      expect(
        page.items.map((e) => e.subject),
        unorderedEquals(['Eski', 'Geç geldi', 'Taşınan']),
      );
    });

    test('archive creates the folder when the account has none', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      expect(rig.imap.folders.containsKey('Archive'), isFalse);
      await rig.gateway.mailAction(ids.single, 'archive');
      expect(rig.imap.folders.containsKey('Archive'), isTrue);
      expect(rig.imap.folders['Archive']!.messages, hasLength(1));
      final folders = await rig.gateway.getFolders();
      expect(folders.where((f) => f.type == 'Archive'), hasLength(1));
    });

    test('move to a chosen folder and copy leave the right copies', () async {
      rig = DirectRig();
      rig.imap.addFolder('Projeler');
      rig.imap.add('INBOX', rigMail('a'));
      rig.imap.add('INBOX', rigMail('b'));
      final ids = await open('Inbox');
      final projects = await folderId('Projeler');
      await rig.gateway.moveMail(ids[0], projects);
      expect(rig.imap.folders['INBOX']!.messages, hasLength(1));
      expect(rig.imap.folders['Projeler']!.messages, hasLength(1));
      await rig.gateway.copyMail(ids[1], projects);
      expect(
        rig.imap.folders['INBOX']!.messages,
        hasLength(1),
        reason: 'copy keeps the source',
      );
      expect(rig.imap.folders['Projeler']!.messages, hasLength(2));
    });

    test('moving to the folder it is already in does nothing', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      rig.imap.resetCalls();
      final result = await rig.gateway.moveMail(
        ids.single,
        await folderId('Inbox'),
      );
      expect(result.success, isTrue);
      expect(rig.imap.count('move'), 0);
    });

    test(
      'restore sends mail from Trash to where it was trashed from',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Trash', use: FolderRole.trash);
        rig.imap.addFolder('Projeler');
        rig.imap.add('Projeler', rigMail('a'));
        final ids = await open('Projeler');
        await rig.gateway.mailAction(ids.single, 'trash');
        await rig.gateway.mailAction(ids.single, 'restore');
        expect(rig.imap.folders['Projeler']!.messages, hasLength(1));
      },
    );

    test('restore without a known origin goes to the Inbox', () async {
      rig = DirectRig();
      rig.imap.addFolder('Trash', use: FolderRole.trash);
      rig.imap.add('Trash', rigMail('a'));
      final ids = await open('Trash');
      await rig.gateway.mailAction(ids.single, 'restore');
      expect(rig.imap.folders['INBOX']!.messages, hasLength(1));
    });

    test('a move that never shows up on the server is dropped', () async {
      rig = DirectRig(capabilities: {'IMAP4REV1', 'NAMESPACE'});
      rig.imap.addFolder('Archive', use: FolderRole.archive);
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      await rig.gateway.mailAction(ids.single, 'archive');
      // Someone else deleted it from the server right after.
      final archive = rig.imap.folders['Archive']!;
      archive.messages.keys.toList().forEach(
        (uid) => rig.imap.remove('Archive', uid),
      );
      rig.clock.advance(const Duration(minutes: 11));
      await rig.gateway.syncFolderId(await folderId('Archive'));
      expect(rig.store.message(rigAccountId, ids.single), isNull);
    });
  });

  group('deleting', () {
    test('permanent delete removes it from the server and the store', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      rig.imap.add('INBOX', rigMail('b'));
      final ids = await open('Inbox');
      final results = await rig.gateway.bulkAction('delete', [ids.first]);
      expect(results.single.success, isTrue);
      expect(rig.imap.folders['INBOX']!.messages, hasLength(1));
      expect(rig.store.message(rigAccountId, ids.first), isNull);
      final folder = (await rig.gateway.getFolders()).first;
      expect(folder.totalCount, 1);
      expect(folder.unreadCount, 1);
    });

    test('while offline nothing is deleted locally', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      await rig.runtime.connection.credentialsChanged();
      rig.imap.failNext('connect', _offline());
      final results = await rig.gateway.bulkAction('delete', ids);
      expect(results.single.canRetry, isTrue);
      expect(rig.store.message(rigAccountId, ids.single), isNotNull);
    });
  });

  group('folders', () {
    test(
      'creating, renaming and moving a folder keeps its mail attached',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Projeler');
        rig.imap.add('INBOX', rigMail('a'));
        final created = await rig.gateway.createFolder('Fatura');
        expect(created.fullName, 'Fatura');
        expect(rig.imap.folders.containsKey('Fatura'), isTrue);

        final inboxIds = await open('Inbox');
        await rig.gateway.moveMail(inboxIds.single, created.id);
        final before = await rig.gateway.getMails(
          folderId: created.id,
          resolveFolder: _resolve,
        );
        expect(before.items, hasLength(1));

        final renamed = await rig.gateway.renameFolder(created.id, 'Faturalar');
        expect(renamed.id, created.id);
        expect(renamed.fullName, 'Faturalar');
        expect(rig.imap.folders.containsKey('Faturalar'), isTrue);

        final parent = await folderId('Projeler');
        final moved = await rig.gateway.setFolderParent(created.id, parent);
        expect(moved.fullName, 'Projeler/Faturalar');
        expect(moved.parentId, parent);
        final after = await rig.gateway.getMails(
          folderId: created.id,
          resolveFolder: _resolve,
        );
        expect(after.items.single.id, before.items.single.id);

        final top = await rig.gateway.setFolderParent(created.id, null);
        expect(top.fullName, 'Faturalar');
        expect(top.parentId, isNull);
      },
    );

    test(
      'on a server where every folder lives under INBOX. they stay top level',
      () async {
        rig = DirectRig(
          addInbox: false,
          namespacePrefix: 'INBOX.',
          delimiter: '.',
        );
        rig.imap.addFolder('INBOX', use: FolderRole.inbox);
        rig.imap.addFolder('INBOX.Sent', use: FolderRole.sent);
        final folders = await rig.gateway.getFolders();
        final sent = folders.firstWhere((f) => f.type == 'Sent');
        expect(sent.parentId, isNull);
        expect(sent.name, 'Sent');

        final created = await rig.gateway.createFolder('Fatura');
        expect(created.fullName, 'INBOX.Fatura');
        expect(created.parentId, isNull);
        final child = await rig.gateway.createFolder(
          '2025',
          parentId: created.id,
        );
        expect(child.fullName, 'INBOX.Fatura.2025');
        expect(child.parentId, created.id);

        final renamed = await rig.gateway.renameFolder(created.id, 'Faturalar');
        expect(renamed.fullName, 'INBOX.Faturalar');
        expect(rig.imap.folders.keys, contains('INBOX.Faturalar'));
        final folderList = await rig.gateway.getFolders();
        expect(
          folderList.firstWhere((f) => f.id == child.id).fullName,
          'INBOX.Faturalar.2025',
          reason: 'children follow their parent',
        );
      },
    );

    test(
      'a server that renames somewhere else does not corrupt the paths',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Projeler');
        rig.imap.addFolder('Projeler/Alt');
        await rig.gateway.getFolders();
        final alt = (await rig.gateway.getFolders()).firstWhere(
          (f) => f.fullName == 'Projeler/Alt',
        );
        // Asked for "Üst", it files the folder under its old parent.
        rig.imap.renameLandsAt = (from, to) => 'Projeler/$to';
        await expectLater(
          rig.gateway.setFolderParent(alt.id, null),
          throwsA(isA<DirectMailException>()),
        );
        final paths = (await rig.gateway.getFolders()).map((f) => f.fullName);
        expect(paths, contains('Projeler/Alt'));
        expect(
          paths,
          isNot(contains('Alt')),
          reason: 'the store says what the server says',
        );
      },
    );

    test('standard folders cannot be renamed, moved or deleted', () async {
      rig = DirectRig();
      await rig.gateway.getFolders();
      final inbox = await folderId('Inbox');
      for (final call in [
        () => rig.gateway.renameFolder(inbox, 'Gelen'),
        () => rig.gateway.setFolderParent(inbox, null),
        () => rig.gateway.deleteFolder(inbox),
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'unsupported_operation',
            ),
          ),
        );
      }
    });

    test('a folder cannot move into itself', () async {
      rig = DirectRig();
      rig.imap.addFolder('A');
      rig.imap.addFolder('A/B');
      final a = await folderId('A');
      final b = await folderId('A/B');
      await expectLater(
        rig.gateway.setFolderParent(a, b),
        throwsA(isA<DirectMailException>()),
      );
    });

    test('deleting removes the folder and its stored mail', () async {
      rig = DirectRig();
      rig.imap.addFolder('Geçici');
      await rig.gateway.getFolders();
      final id = await folderId('Geçici');
      await rig.gateway.deleteFolder(id);
      expect(rig.imap.folders.containsKey('Geçici'), isFalse);
      expect(rig.store.folder(rigAccountId, id), isNull);
      expect(
        (await rig.gateway.getFolders()).where((f) => f.id == id),
        isEmpty,
      );
    });

    test('a role chosen by the user moves to the newest choice', () async {
      rig = DirectRig();
      rig.imap.addFolder('Giden');
      rig.imap.addFolder('Yollanan');
      await rig.gateway.getFolders();
      final a = await folderId('Giden');
      final b = await folderId('Yollanan');
      final first = await rig.gateway.setFolderRole(a, 'Sent');
      expect(first.type, 'Sent');
      expect(first.roleOverride, 'Sent');
      await rig.gateway.setFolderRole(b, 'Sent');
      final folders = await rig.gateway.getFolders();
      expect(folders.firstWhere((f) => f.id == a).type, 'Custom');
      expect(folders.firstWhere((f) => f.id == b).type, 'Sent');
      final cleared = await rig.gateway.setFolderRole(b, null);
      expect(cleared.roleOverride, isNull);
      await expectLater(
        rig.gateway.setFolderRole(a, 'Inbox'),
        throwsA(isA<DirectMailException>()),
      );
    });
  });

  test('the result list keeps the order the ids were given in', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('a'));
    rig.imap.add('INBOX', rigMail('b'));
    rig.imap.add('INBOX', rigMail('c'));
    final ids = await open('Inbox');
    final shuffled = [ids[1], 'd:missing', ids[0], ids[2]];
    final results = await rig.gateway.bulkAction('read', shuffled);
    expect(results.map((r) => r.mailId), shuffled);
    expect(results.map((r) => r.success), [true, false, true, true]);
    expect(const SyncOptions().hotFlagWindow, greaterThan(0));
    expect(BulkActionResult(mailId: 'x', success: true).canRetry, isFalse);
  });
}
