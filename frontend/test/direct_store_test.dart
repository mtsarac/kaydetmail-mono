import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/mail_recipients.dart';
import 'package:sqlite3/sqlite3.dart';

DirectStore _store() {
  var n = 0;
  return DirectStore(sqlite3.openInMemory(), newId: () => '${++n}');
}

DirectAccountConfig _config(String id, [String email = 'ada@example.com']) =>
    DirectAccountConfig(
      id: id,
      email: email,
      displayName: 'Ada',
      imap: const DirectEndpoint(
        host: 'imap.example.com',
        port: 993,
        security: MailSecurity.sslOnConnect,
        username: 'ada',
      ),
      smtp: const DirectEndpoint(
        host: 'smtp.example.com',
        port: 587,
        security: MailSecurity.startTls,
        username: 'ada',
      ),
    );

RemoteFolder _folder(
  String path, {
  String delimiter = '/',
  FolderRole? use,
  Set<String> attributes = const {},
}) => RemoteFolder(
  path: path,
  name: delimiter.isEmpty ? path : path.split(delimiter).last,
  delimiter: delimiter,
  specialUse: use,
  attributes: attributes,
);

MessageDraft _msg(
  String account,
  String folder,
  int uid, {
  String subject = 's',
  int sortMs = 1000,
  bool read = false,
  String messageId = '',
  String thread = '',
}) => MessageDraft(
  accountId: account,
  folderId: folder,
  uid: uid,
  uidValidity: 7,
  subject: subject,
  sortMs: sortMs + uid,
  dateMs: sortMs + uid,
  isRead: read,
  messageId: messageId,
  threadId: thread,
  fromAddress: 'from@example.com',
);

void main() {
  group('schema', () {
    test('migrates once and is safe to open again', () {
      final db = sqlite3.openInMemory();
      expect(DirectStore(db).schemaVersion, DirectStore.latestSchemaVersion);
      expect(DirectStore(db).schemaVersion, DirectStore.latestSchemaVersion);
    });

    test('every d_ table is keyed by account_id (so removal can be exact)', () {
      final store = _store();
      final tables = store.db
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name LIKE 'd\\_%' ESCAPE '\\' AND name <> 'd_schema'",
          )
          .map((r) => r['name'] as String);
      expect(tables, isNotEmpty);
      for (final table in tables) {
        final columns = store.db
            .select('PRAGMA table_info($table)')
            .map((r) => r['name']);
        expect(columns, contains('account_id'), reason: table);
      }
    });
  });

  group('accounts', () {
    test('round-trips an account without any password', () {
      final store = _store()..saveAccount(_config('a1'));
      final read = store.account('a1')!;
      expect(read.email, 'ada@example.com');
      expect(read.imap.security, MailSecurity.sslOnConnect);
      expect(read.smtp.security, MailSecurity.startTls);
      expect(store.accounts().single.id, 'a1');
    });

    test('removing one account leaves another untouched', () {
      final store = _store()
        ..saveAccount(_config('a1'))
        ..saveAccount(_config('a2', 'b@example.com'));
      for (final id in ['a1', 'a2']) {
        store.replaceFolders(id, [_folder('INBOX', use: FolderRole.inbox)]);
        final folder = store.folderByRole(id, FolderRole.inbox)!;
        final local = store.upsertMessage(_msg(id, folder.folderId, 1));
        store.saveBody(id, local, const BodyDraft(text: 'hi'), const [
          PartDraft(
            partId: '2',
            filename: 'a.txt',
            mime: 'text/plain',
            size: 3,
          ),
        ]);
        store.createThread(id, normalizedSubject: 's', atMs: 1);
      }

      store.removeAccount('a1');

      expect(store.account('a1'), isNull);
      expect(store.folders('a1'), isEmpty);
      for (final table in [
        'd_messages',
        'd_bodies',
        'd_parts',
        'd_threads',
        'd_folders',
      ]) {
        final rows = store.db
            .select('SELECT account_id FROM $table')
            .map((r) => r['account_id'])
            .toSet();
        expect(rows, {'a2'}, reason: table);
      }
    });
  });

  group('folders', () {
    test('roles come from SPECIAL-USE first, then names, Turkish included', () {
      FolderRole role(String path, {String d = '/', FolderRole? use}) =>
          DirectStore.detectRole(_folder(path, delimiter: d, use: use));
      expect(role('INBOX'), FolderRole.inbox);
      expect(role('inbox'), FolderRole.inbox);
      expect(role('Weird', use: FolderRole.sent), FolderRole.sent);
      expect(role('INBOX.Sent', d: '.'), FolderRole.sent);
      expect(role('INBOX.Drafts', d: '.'), FolderRole.drafts);
      expect(role('Sent Items'), FolderRole.sent);
      expect(role('Deleted Items'), FolderRole.trash);
      expect(role('Gönderilmiş Öğeler'), FolderRole.sent);
      expect(role('Taslaklar'), FolderRole.drafts);
      expect(role('Çöp Kutusu'), FolderRole.trash);
      expect(role('Önemsiz'), FolderRole.junk);
      expect(role('Spam'), FolderRole.junk);
      expect(role('Arşiv'), FolderRole.archive);
      expect(role('Projeler'), FolderRole.custom);
      // The server's own statement beats the name.
      expect(role('Trash', use: FolderRole.archive), FolderRole.archive);
    });

    test('keeps ids by path, links parents, hides vanished folders', () {
      final store = _store();
      store.replaceFolders('a', [
        _folder('INBOX', use: FolderRole.inbox),
        _folder('Projeler'),
        _folder('Projeler/2026'),
      ]);
      final first = {for (final f in store.folders('a')) f.path: f};
      expect(
        first['Projeler/2026']!.parentFolderId,
        first['Projeler']!.folderId,
      );
      expect(first['Projeler']!.parentFolderId, isNull);

      store.replaceFolders('a', [_folder('INBOX', use: FolderRole.inbox)]);
      expect(store.folders('a').map((f) => f.path), ['INBOX']);
      final gone = store.folderByPath('a', 'Projeler')!;
      expect(gone.available, isFalse);
      expect(gone.folderId, first['Projeler']!.folderId);

      store.replaceFolders('a', [
        _folder('INBOX', use: FolderRole.inbox),
        _folder('Projeler'),
      ]);
      expect(store.folderByPath('a', 'Projeler')!.available, isTrue);
      expect(
        store.folderByPath('a', 'Projeler')!.folderId,
        first['Projeler']!.folderId,
      );
    });

    test('Inbox and Sent sync by default; a later choice is kept', () {
      final store = _store();
      store.replaceFolders('a', [
        _folder('INBOX', use: FolderRole.inbox),
        _folder('Sent', use: FolderRole.sent),
        _folder('Spam', use: FolderRole.junk),
        _folder('Shared', attributes: const {r'\noselect'}),
      ]);
      final byPath = {for (final f in store.folders('a')) f.path: f};
      expect(byPath['INBOX']!.syncEnabled, isTrue);
      expect(byPath['Sent']!.syncEnabled, isTrue);
      expect(byPath['Spam']!.syncEnabled, isFalse);
      expect(byPath['Shared']!.selectable, isFalse);

      store.setFolderSyncEnabled('a', byPath['Spam']!.folderId, true);
      store.setFolderSyncEnabled('a', byPath['Sent']!.folderId, false);
      store.replaceFolders('a', [
        _folder('INBOX', use: FolderRole.inbox),
        _folder('Sent', use: FolderRole.sent),
        _folder('Spam', use: FolderRole.junk),
      ]);
      final again = {for (final f in store.folders('a')) f.path: f};
      expect(again['Spam']!.syncEnabled, isTrue);
      expect(again['Sent']!.syncEnabled, isFalse);
    });

    test('a user-assigned role wins over the detected one', () {
      final store = _store()..replaceFolders('a', [_folder('Giden')]);
      final f = store.folders('a').single;
      expect(f.role, FolderRole.custom);
      store.setFolderRoleOverride('a', f.folderId, FolderRole.sent);
      expect(store.folderByRole('a', FolderRole.sent)?.path, 'Giden');
      store.setFolderRoleOverride('a', f.folderId, null);
      expect(store.folderByRole('a', FolderRole.sent), isNull);
    });
  });

  group('messages', () {
    late DirectStore store;
    late String inbox;
    setUp(() {
      store = _store()
        ..replaceFolders('a', [_folder('INBOX', use: FolderRole.inbox)]);
      inbox = store.folderByRole('a', FolderRole.inbox)!.folderId;
    });

    test('upsert keeps the local id and updates flags in place', () {
      final id = store.upsertMessage(_msg('a', inbox, 5));
      final again = store.upsertMessage(_msg('a', inbox, 5, read: true));
      expect(again, id);
      expect(store.count('a', inbox), 1);
      expect(store.message('a', id)!.isRead, isTrue);
    });

    test('pages are newest first and exclude hidden rows', () {
      for (var uid = 1; uid <= 5; uid++) {
        store.upsertMessage(_msg('a', inbox, uid, sortMs: uid * 100));
      }
      store.db.execute(
        'UPDATE d_messages SET hidden = 1 WHERE uid = 5 AND account_id = ?',
        ['a'],
      );
      final page = store.page('a', inbox, offset: 0, limit: 2);
      expect(page.map((m) => m.uid), [4, 3]);
      expect(store.page('a', inbox, offset: 2, limit: 10).map((m) => m.uid), [
        2,
        1,
      ]);
      expect(store.count('a', inbox), 4);
    });

    test('unread counts and unread-only pages', () {
      store.upsertMessage(_msg('a', inbox, 1, read: true));
      store.upsertMessage(_msg('a', inbox, 2));
      store.upsertMessage(_msg('a', inbox, 3));
      expect(store.unreadCount('a', inbox), 2);
      expect(
        store.page('a', inbox, offset: 0, limit: 10, unreadOnly: true).length,
        2,
      );
    });

    test('flags can be diffed by UID and updated', () {
      final id = store.upsertMessage(_msg('a', inbox, 1));
      final flags = store.flagsByUid('a', inbox);
      expect(flags[1]!.isRead, isFalse);
      store.updateFlags(
        'a',
        id,
        isRead: true,
        isFlagged: true,
        isAnswered: false,
        isDraft: false,
        isForwarded: true,
        isDeleted: false,
        keywords: const [r'$Label1'],
      );
      final m = store.message('a', id)!;
      expect([m.isRead, m.isFlagged, m.isForwarded], [true, true, true]);
      expect(m.keywords, [r'$Label1']);
    });

    test('messages gone from the server are deleted with their bodies', () {
      final id = store.upsertMessage(_msg('a', inbox, 1));
      store.saveBody('a', id, const BodyDraft(text: 'x'), const []);
      store.deleteByUids('a', inbox, [1]);
      expect(store.message('a', id), isNull);
      expect(store.body('a', id), isNull);
    });

    test('a UIDVALIDITY reset keeps rows so annotations can be re-bound', () {
      final id = store.upsertMessage(_msg('a', inbox, 1, messageId: 'm1@x'));
      store.markFolderStale('a', inbox);
      expect(store.count('a', inbox), 0);
      final stale = store.staleMessages('a', inbox);
      expect(stale.single.localId, id);

      store.rebindMessage(id, _msg('a', inbox, 90, messageId: 'm1@x'));
      final rebound = store.message('a', id)!;
      expect(rebound.uid, 90);
      expect(store.staleMessages('a', inbox), isEmpty);
      expect(store.messageByUid('a', inbox, 90)!.localId, id);
    });

    test('the same UID cannot be stored twice in a folder', () {
      store.upsertMessage(_msg('a', inbox, 1));
      expect(
        () => store.db.execute(
          "INSERT INTO d_messages (account_id, local_id, folder_id, uid, sort_ms, date_ms) "
          "VALUES ('a','dup', ?, 1, 1, 1)",
          [inbox],
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('bodies and parts are stored with the message', () {
      final id = store.upsertMessage(_msg('a', inbox, 1));
      store.saveBody(
        'a',
        id,
        const BodyDraft(
          text: 'merhaba',
          html: '<p>merhaba</p>',
          hasRemoteContent: true,
          remoteImageHosts: ['cdn.example.com'],
          snippet: 'merhaba',
        ),
        const [
          PartDraft(
            partId: '2',
            filename: 'rapor.pdf',
            mime: 'application/pdf',
            size: 10,
          ),
          PartDraft(
            partId: '3',
            filename: 'logo.png',
            mime: 'image/png',
            size: 5,
            contentId: 'logo',
            isInline: true,
          ),
        ],
      );
      final body = store.body('a', id)!;
      expect(body.html, '<p>merhaba</p>');
      expect(body.remoteImageHosts, ['cdn.example.com']);
      expect(store.parts('a', id).map((p) => p.filename), [
        'rapor.pdf',
        'logo.png',
      ]);
      final row = store.message('a', id)!;
      expect(row.bodyLoaded, isTrue);
      expect(row.hasAttachments, isTrue);
      expect(row.snippet, 'merhaba');
    });

    test('recipients survive storage with their display names', () {
      store.upsertMessage(
        MessageDraft(
          accountId: 'a',
          folderId: inbox,
          uid: 1,
          uidValidity: 7,
          sortMs: 1,
          dateMs: 1,
          to: const [MailRecipient('b@x.test', 'Bay B')],
          cc: const [MailRecipient('c@x.test')],
        ),
      );
      final m = store.messageByUid('a', inbox, 1)!;
      expect(m.to.single.displayName, 'Bay B');
      expect(m.cc.single.address, 'c@x.test');
    });
  });

  group('threads', () {
    test('merging moves messages into the surviving thread', () {
      final store = _store()
        ..replaceFolders('a', [_folder('INBOX', use: FolderRole.inbox)]);
      final inbox = store.folderByRole('a', FolderRole.inbox)!.folderId;
      final t1 = store.createThread('a', normalizedSubject: 'x', atMs: 100);
      final t2 = store.createThread('a', normalizedSubject: 'x', atMs: 50);
      store.upsertMessage(_msg('a', inbox, 1, thread: t1));
      store.upsertMessage(_msg('a', inbox, 2, thread: t2));

      store.mergeThreads('a', t1, [t2]);

      expect(store.messageByUid('a', inbox, 2)!.threadId, t1);
      expect(store.thread('a', t2), isNull);
      expect(store.thread('a', t1)!.startedMs, 50);
    });
  });
}
