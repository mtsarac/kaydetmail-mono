import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/fake_imap_service.dart';

const _acc = 'acc';
const _own = 'me@example.com';

String raw(
  String id, {
  String subject = 'Konu',
  String from = 'ayse@example.org',
  String to = _own,
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

class _Rig {
  _Rig({SyncOptions options = const SyncOptions(), Set<String>? capabilities})
    : store = DirectStore(sqlite3.openInMemory()),
      imap = capabilities == null
          ? FakeImapService()
          : FakeImapService(capabilities: capabilities) {
    imap.addFolder('INBOX', use: FolderRole.inbox);
    engine = SyncEngine(
      store: store,
      imap: imap,
      accountId: _acc,
      ownAddress: _own,
      options: options,
    );
  }

  final DirectStore store;
  final FakeImapService imap;
  late final SyncEngine engine;

  Future<String> inbox() async {
    await engine.syncFolderList();
    return store.folderByRole(_acc, FolderRole.inbox)!.folderId;
  }

  List<int> stored(String folderId) => store.uids(_acc, folderId);
}

void main() {
  group('first sync', () {
    test(
      'takes the newest window and leaves older mail for backfill',
      () async {
        final rig = _Rig(
          options: const SyncOptions(initialWindow: 10, prefetchBodies: 0),
        );
        for (var i = 1; i <= 25; i++) {
          rig.imap.add('INBOX', raw('m$i', subject: 'Mail $i'));
        }
        final inbox = await rig.inbox();

        final report = await rig.engine.syncFolder(inbox);

        expect(rig.stored(inbox), [for (var u = 16; u <= 25; u++) u]);
        expect(report.newLocalIds, hasLength(10));
        final folder = rig.store.folder(_acc, inbox)!;
        expect(folder.uidValidity, 100);
        expect(folder.uidNext, 26);
        expect(folder.remoteExists, 25);
        expect(folder.oldestSyncedUid, 16);
        expect(folder.backfillComplete, isFalse);
        expect(folder.lastSyncMs, isNotNull);
      },
    );

    test('a small folder is complete at once', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      for (var i = 1; i <= 3; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      expect(rig.store.folder(_acc, inbox)!.backfillComplete, isTrue);
    });

    test('an empty folder is complete and costs no fetch', () async {
      final rig = _Rig();
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      expect(rig.store.folder(_acc, inbox)!.backfillComplete, isTrue);
      expect(rig.imap.count('fetchHeaders'), 0);
    });

    test('a sparse UID space is searched without listing everything', () async {
      final rig = _Rig(
        options: const SyncOptions(initialWindow: 5, prefetchBodies: 0),
      );
      for (var i = 1; i <= 400; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }
      // Only every 20th message survives, so UIDs are 20 apart.
      for (var uid = 1; uid <= 400; uid++) {
        if (uid % 20 != 0) rig.imap.remove('INBOX', uid);
      }
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      expect(rig.stored(inbox), [320, 340, 360, 380, 400]);
    });

    test(
      'each message gets its own conversation unless it is linked',
      () async {
        final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
        rig.imap.add('INBOX', raw('a', subject: 'Birinci'));
        rig.imap.add(
          'INBOX',
          raw('b', subject: 'İkinci', from: 'can@example.org'),
        );
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        final rows = rig.store.page(_acc, inbox, offset: 0, limit: 10);
        expect(rows.map((r) => r.threadId).toSet(), hasLength(2));
      },
    );
  });

  group('incremental sync', () {
    test('nothing changed costs one flag read and no header fetch', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      for (var i = 1; i <= 5; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);

      rig.imap.resetCalls();
      final report = await rig.engine.syncFolder(inbox);

      expect(report.newLocalIds, isEmpty);
      expect(rig.imap.count('fetchHeaders'), 0);
      expect(rig.imap.count('listUids'), 0);
      expect(rig.imap.count('fetchFlags'), 1);
      expect(rig.imap.count('select'), 1);
    });

    test('new mail is ingested once, never twice', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      rig.imap.add('INBOX', raw('m1'));
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);

      rig.imap.add('INBOX', raw('m2'));
      rig.imap.add('INBOX', raw('m3'));
      final first = await rig.engine.syncFolder(inbox);
      final again = await rig.engine.syncFolder(inbox);

      expect(first.newLocalIds, hasLength(2));
      expect(again.newLocalIds, isEmpty);
      expect(rig.stored(inbox), [1, 2, 3]);
      expect(rig.store.count(_acc, inbox), 3);
    });

    test(
      'a message deleted on the server disappears here with its body',
      () async {
        final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
        for (var i = 1; i <= 4; i++) {
          rig.imap.add('INBOX', raw('m$i'));
        }
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        final doomed = rig.store.messageByUid(_acc, inbox, 2)!;
        await rig.engine.ensureBody(doomed.localId);
        expect(rig.store.body(_acc, doomed.localId), isNotNull);

        rig.imap.remove('INBOX', 2);
        final report = await rig.engine.syncFolder(inbox);

        expect(report.removed, 1);
        expect(rig.stored(inbox), [1, 3, 4]);
        expect(rig.store.message(_acc, doomed.localId), isNull);
        expect(rig.store.body(_acc, doomed.localId), isNull);
      },
    );

    test(
      'an arrival and an expunge in the same interval are both seen',
      () async {
        final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
        for (var i = 1; i <= 3; i++) {
          rig.imap.add('INBOX', raw('m$i'));
        }
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);

        rig.imap.remove('INBOX', 1);
        rig.imap.add('INBOX', raw('m4'));
        // EXISTS is the same as before; only UIDNEXT tells.
        expect(rig.imap.folders['INBOX']!.messages.length, 3);
        await rig.engine.syncFolder(inbox);

        expect(rig.stored(inbox), [2, 3, 4]);
      },
    );

    test('flags changed elsewhere are picked up', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      rig.imap.add('INBOX', raw('m1'));
      rig.imap.add('INBOX', raw('m2'), flags: {r'\Seen'});
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      expect(rig.store.messageByUid(_acc, inbox, 1)!.isRead, isFalse);

      rig.imap.setFlags('INBOX', 1, {
        r'\Seen',
        r'\Flagged',
        r'$Forwarded',
        r'$Label1',
      });
      rig.imap.setFlags('INBOX', 2, {});
      final report = await rig.engine.syncFolder(inbox);

      final one = rig.store.messageByUid(_acc, inbox, 1)!;
      expect([one.isRead, one.isFlagged, one.isForwarded], [true, true, true]);
      expect(one.keywords, [r'$Label1']);
      expect(rig.store.messageByUid(_acc, inbox, 2)!.isRead, isFalse);
      expect(report.flagChanges, 2);
    });

    test('old flags are re-read only on a full pass', () async {
      final rig = _Rig(
        options: const SyncOptions(hotFlagWindow: 2, prefetchBodies: 0),
      );
      for (var i = 1; i <= 6; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);

      rig.imap.setFlags('INBOX', 1, {r'\Seen'});
      rig.imap.setFlags('INBOX', 6, {r'\Seen'});
      await rig.engine.syncFolder(inbox);
      expect(rig.store.messageByUid(_acc, inbox, 6)!.isRead, isTrue);
      expect(rig.store.messageByUid(_acc, inbox, 1)!.isRead, isFalse);

      await rig.engine.syncFolder(inbox, full: true);
      expect(rig.store.messageByUid(_acc, inbox, 1)!.isRead, isTrue);
    });

    test('CONDSTORE asks only for what changed since the last pass', () async {
      final rig = _Rig(
        options: const SyncOptions(useCondStore: true, prefetchBodies: 0),
        capabilities: {'IMAP4REV1', 'CONDSTORE', 'UIDPLUS'},
      );
      for (var i = 1; i <= 3; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      rig.imap.setFlags('INBOX', 2, {r'\Seen'});

      rig.imap.resetCalls();
      await rig.engine.syncFolder(inbox);

      expect(rig.imap.count('fetchFlagsChangedSince'), 1);
      expect(rig.imap.count('fetchFlags'), 0);
      expect(rig.store.messageByUid(_acc, inbox, 2)!.isRead, isTrue);
    });
  });

  group('UIDVALIDITY', () {
    test(
      'a renumbered folder re-binds messages and keeps their local ids',
      () async {
        final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
        rig.imap.add('INBOX', raw('m1', subject: 'Bir'));
        rig.imap.add('INBOX', raw('m2', subject: 'İki'));
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        final before = {
          for (final m in rig.store.page(_acc, inbox, offset: 0, limit: 10))
            m.messageId: m.localId,
        };

        rig.imap.changeUidValidity('INBOX', 555);
        // And one more arrives afterwards.
        rig.imap.add('INBOX', raw('m3', subject: 'Üç'));
        final report = await rig.engine.syncFolder(inbox);

        expect(report.uidValidityChanged, isTrue);
        final after = {
          for (final m in rig.store.page(_acc, inbox, offset: 0, limit: 10))
            m.messageId: m.localId,
        };
        expect(after['m1@example.org'], before['m1@example.org']);
        expect(after['m2@example.org'], before['m2@example.org']);
        expect(after, hasLength(3));
        expect(rig.store.folder(_acc, inbox)!.uidValidity, 555);
        expect(rig.stored(inbox), [1, 2, 3]);
        expect(rig.store.staleMessages(_acc, inbox), isEmpty);
      },
    );

    test('a message that did not come back stays out of the list', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      rig.imap.add('INBOX', raw('m1'));
      rig.imap.add('INBOX', raw('m2'));
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);

      rig.imap.changeUidValidity('INBOX', 9);
      rig.imap.remove('INBOX', 2); // m2 is gone after renumbering
      await rig.engine.syncFolder(inbox);

      expect(rig.store.count(_acc, inbox), 1);
      expect(
        rig.store.page(_acc, inbox, offset: 0, limit: 10).single.messageId,
        'm1@example.org',
      );
    });
  });

  group('interruptions', () {
    test(
      'a failure between batches loses nothing and the next pass finishes',
      () async {
        final rig = _Rig(
          options: const SyncOptions(headerBatch: 2, prefetchBodies: 0),
        );
        rig.imap.add('INBOX', raw('m0'));
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        for (var i = 1; i <= 6; i++) {
          rig.imap.add('INBOX', raw('m$i'));
        }
        // The first batch arrives, the connection drops during the second.
        rig.imap.failOnNthCall(
          'fetchHeaders',
          2,
          const SocketException('Connection reset by peer'),
        );

        await expectLater(
          rig.engine.syncFolder(inbox),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.category,
              'category',
              ApiErrorCategory.network,
            ),
          ),
        );
        expect(rig.stored(inbox), [
          1,
          2,
          3,
        ], reason: 'the finished batch is kept');
        expect(rig.store.folder(_acc, inbox)!.consecutiveFailures, 1);

        await rig.engine.syncFolder(inbox);
        expect(rig.stored(inbox), [1, 2, 3, 4, 5, 6, 7]);
        expect(rig.store.count(_acc, inbox), 7);
        expect(rig.store.folder(_acc, inbox)!.consecutiveFailures, 0);
      },
    );

    test(
      'mail that arrives in an empty folder and is cut off leaves no hole',
      () async {
        final rig = _Rig(
          options: const SyncOptions(headerBatch: 2, prefetchBodies: 0),
        );
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox); // empty folder: marked complete
        expect(rig.store.folder(_acc, inbox)!.backfillComplete, isTrue);
        for (var i = 1; i <= 6; i++) {
          rig.imap.add('INBOX', raw('m$i'));
        }
        rig.imap.failOnNthCall(
          'fetchHeaders',
          2,
          const SocketException('reset'),
        );
        await expectLater(
          rig.engine.syncFolder(inbox),
          throwsA(isA<DirectMailException>()),
        );
        // Newest batch first, so what is missing is the older part.
        expect(rig.stored(inbox), [5, 6]);
        expect(rig.store.folder(_acc, inbox)!.backfillComplete, isFalse);

        await rig.engine.syncFolder(inbox);
        while (!rig.store.folder(_acc, inbox)!.backfillComplete) {
          await rig.engine.backfill(inbox, count: 2);
        }
        expect(rig.stored(inbox), [1, 2, 3, 4, 5, 6]);
      },
    );

    test('a spent budget stops cleanly and the next pass continues', () async {
      final rig = _Rig(
        options: const SyncOptions(headerBatch: 2, prefetchBodies: 0),
      );
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      for (var i = 1; i <= 7; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }

      final stopped = await rig.engine.syncFolder(inbox, budget: Duration.zero);
      expect(stopped.stoppedEarly, isTrue);
      expect(rig.store.count(_acc, inbox), lessThan(7));

      final done = await rig.engine.syncFolder(inbox);
      expect(done.stoppedEarly, isFalse);
      while (!rig.store.folder(_acc, inbox)!.backfillComplete) {
        await rig.engine.backfill(inbox, count: 3);
      }
      expect(rig.stored(inbox), [1, 2, 3, 4, 5, 6, 7]);
    });

    test('the per-pass cap leaves the rest for the next pass', () async {
      final rig = _Rig(
        options: const SyncOptions(
          maxNewPerPass: 3,
          headerBatch: 2,
          prefetchBodies: 0,
        ),
      );
      rig.imap.add('INBOX', raw('m0'));
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      for (var i = 1; i <= 8; i++) {
        rig.imap.add('INBOX', raw('m$i'));
      }
      final first = await rig.engine.syncFolder(inbox);
      expect(first.stoppedEarly, isTrue);
      expect(rig.stored(inbox), [1, 2, 3, 4]);
      await rig.engine.syncFolder(inbox);
      await rig.engine.syncFolder(inbox);
      expect(rig.stored(inbox), [for (var u = 1; u <= 9; u++) u]);
    });

    test(
      'an interrupted first sync keeps the newest mail and leaves no hole',
      () async {
        final rig = _Rig(
          options: const SyncOptions(
            initialWindow: 6,
            headerBatch: 2,
            prefetchBodies: 0,
          ),
        );
        for (var i = 1; i <= 12; i++) {
          rig.imap.add('INBOX', raw('m$i'));
        }
        final inbox = await rig.inbox();
        // The newest batch arrives; the connection drops on the next one.
        rig.imap.failOnNthCall(
          'fetchHeaders',
          2,
          const SocketException('reset'),
        );
        await expectLater(
          rig.engine.syncFolder(inbox),
          throwsA(isA<DirectMailException>()),
        );
        expect(rig.stored(inbox), [11, 12]);

        await rig.engine.syncFolder(inbox);
        expect(rig.stored(inbox), [
          11,
          12,
        ], reason: 'nothing new above the window');
        expect(rig.store.folder(_acc, inbox)!.backfillComplete, isFalse);

        // Backfill continues below the oldest stored message, covering the
        // part of the window that was missed.
        while (!rig.store.folder(_acc, inbox)!.backfillComplete) {
          await rig.engine.backfill(inbox, count: 4);
        }
        expect(rig.stored(inbox), [for (var u = 1; u <= 12; u++) u]);
      },
    );
  });

  group('backfill', () {
    test(
      'older mail comes in chunks, newest of the old first, until done',
      () async {
        final rig = _Rig(
          options: const SyncOptions(initialWindow: 4, prefetchBodies: 0),
        );
        for (var i = 1; i <= 11; i++) {
          rig.imap.add('INBOX', raw('m$i'));
        }
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        expect(rig.stored(inbox), [8, 9, 10, 11]);

        expect(await rig.engine.backfill(inbox, count: 4), 4);
        expect(rig.stored(inbox), [4, 5, 6, 7, 8, 9, 10, 11]);
        expect(rig.store.folder(_acc, inbox)!.backfillComplete, isFalse);

        expect(await rig.engine.backfill(inbox, count: 4), 3);
        expect(rig.stored(inbox), [for (var u = 1; u <= 11; u++) u]);
        expect(rig.store.folder(_acc, inbox)!.backfillComplete, isTrue);
        expect(await rig.engine.backfill(inbox, count: 4), 0);
        expect(rig.store.count(_acc, inbox), 11);
      },
    );
  });

  group('bodies', () {
    test('new mail gets a preview from a prefetched body', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 5));
      rig.imap.add('INBOX', raw('m1', body: 'Toplantı yarın saat 10:00.'));
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      final row = rig.store.messageByUid(_acc, inbox, 1)!;
      expect(row.bodyLoaded, isTrue);
      expect(row.snippet, 'Toplantı yarın saat 10:00.');
    });

    test(
      'only the newest few are prefetched, and not oversized ones',
      () async {
        final rig = _Rig(
          options: const SyncOptions(prefetchBodies: 2, maxPrefetchBytes: 400),
        );
        rig.imap.add('INBOX', raw('m1'));
        rig.imap.add('INBOX', raw('m2', body: 'x' * 2000)); // too big
        rig.imap.add('INBOX', raw('m3'));
        rig.imap.add('INBOX', raw('m4'));
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        bool loaded(int uid) =>
            rig.store.messageByUid(_acc, inbox, uid)!.bodyLoaded;
        expect(
          [loaded(4), loaded(3), loaded(2), loaded(1)],
          [true, true, false, false],
        );
      },
    );

    test('opening a message fetches its body once', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      rig.imap.add('INBOX', raw('m1', body: 'selam'));
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      final id = rig.store.messageByUid(_acc, inbox, 1)!.localId;
      rig.imap.resetCalls();
      await rig.engine.ensureBody(id);
      await rig.engine.ensureBody(id);
      expect(rig.imap.count('fetchFull'), 1);
      expect(rig.store.body(_acc, id)!.text, 'selam');
    });

    test(
      'a body that vanished from the server is reported as not found',
      () async {
        final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
        rig.imap.add('INBOX', raw('m1'));
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        final id = rig.store.messageByUid(_acc, inbox, 1)!.localId;
        rig.imap.remove('INBOX', 1);
        expect(
          () => rig.engine.ensureBody(id),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.kind,
              'kind',
              DirectErrorKind.mailNotFound,
            ),
          ),
        );
      },
    );
  });

  group('conversations', () {
    test('a reply joins its parent whichever arrives first', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      rig.imap.add(
        'INBOX',
        raw(
          'reply',
          subject: 'Re: Plan',
          inReplyTo: 'parent',
          from: 'can@example.org',
        ),
      );
      rig.imap.add(
        'INBOX',
        raw('parent', subject: 'Plan', from: 'ayse@example.org'),
      );
      final inbox = await rig.inbox();
      await rig.engine.syncFolder(inbox);
      final a = rig.store.messageByUid(_acc, inbox, 1)!;
      final b = rig.store.messageByUid(_acc, inbox, 2)!;
      expect(a.threadId, b.threadId);
    });

    test(
      'unrelated mail with the same subject and no shared person stays apart',
      () async {
        final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
        rig.imap.add(
          'INBOX',
          raw('a', subject: 'Fatura', from: 'a@one.test', to: _own),
        );
        rig.imap.add(
          'INBOX',
          raw('b', subject: 'Fatura', from: 'b@two.test', to: _own),
        );
        final inbox = await rig.inbox();
        await rig.engine.syncFolder(inbox);
        expect(
          rig.store.messageByUid(_acc, inbox, 1)!.threadId,
          isNot(rig.store.messageByUid(_acc, inbox, 2)!.threadId),
        );
      },
    );
  });

  group('folders', () {
    test(
      'the folder list follows the server, including cPanel naming',
      () async {
        final rig = _Rig();
        rig.imap.folders.clear();
        rig.imap.addFolder('INBOX', use: FolderRole.inbox);
        for (final name in [
          'INBOX.Sent',
          'INBOX.Drafts',
          'INBOX.Trash',
          'INBOX.Spam',
          'INBOX.Projeler',
        ]) {
          rig.imap.folders[name] = FakeFolder(name, delimiter: '.');
        }
        final folders = await rig.engine.syncFolderList();
        final roles = {for (final f in folders) f.path: f.role};
        expect(roles['INBOX'], FolderRole.inbox);
        expect(roles['INBOX.Sent'], FolderRole.sent);
        expect(roles['INBOX.Drafts'], FolderRole.drafts);
        expect(roles['INBOX.Trash'], FolderRole.trash);
        expect(roles['INBOX.Spam'], FolderRole.junk);
        expect(roles['INBOX.Projeler'], FolderRole.custom);
        expect(
          folders.firstWhere((f) => f.path == 'INBOX.Projeler').parentFolderId,
          folders.firstWhere((f) => f.path == 'INBOX').folderId,
        );
      },
    );

    test('a folder removed on the server is hidden, not wiped', () async {
      final rig = _Rig(options: const SyncOptions(prefetchBodies: 0));
      rig.imap.addFolder('Eski');
      rig.imap.add('Eski', raw('x1'));
      await rig.engine.syncFolderList();
      final old = rig.store.folderByPath(_acc, 'Eski')!;
      await rig.engine.syncFolder(old.folderId);
      expect(rig.store.count(_acc, old.folderId), 1);

      rig.imap.folders.remove('Eski');
      await rig.engine.syncFolderList();
      expect(rig.store.folders(_acc).map((f) => f.path), ['INBOX']);
      expect(rig.store.count(_acc, old.folderId), 1);
    });
  });

  group('failures', () {
    test(
      'a lost connection is reported as a network failure and recorded',
      () async {
        final rig = _Rig();
        final inbox = await rig.inbox();
        rig.imap.failNext(
          'select',
          const SocketException(
            'Failed host lookup',
            osError: OSError('No address associated with hostname', 7),
          ),
        );
        await expectLater(
          rig.engine.syncFolder(inbox),
          throwsA(
            isA<DirectMailException>().having(
              (e) => e.kind,
              'kind',
              DirectErrorKind.dnsFailure,
            ),
          ),
        );
        final folder = rig.store.folder(_acc, inbox)!;
        expect(folder.consecutiveFailures, 1);
        expect(folder.lastFailureCode, 'dns_failure');
      },
    );

    test('an unselectable folder is skipped without a call', () async {
      final rig = _Rig();
      rig.imap.folders['Paylasilan'] = FakeFolder('Paylasilan');
      await rig.engine.syncFolderList();
      final id = rig.store.folderByPath(_acc, 'Paylasilan')!.folderId;
      rig.store.db.execute(
        "UPDATE d_folders SET attributes = '\\noselect' WHERE folder_id = ?",
        [id],
      );
      rig.imap.resetCalls();
      await rig.engine.syncFolder(id);
      expect(rig.imap.count('select'), 0);
    });
  });
}
