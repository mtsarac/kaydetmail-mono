import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';

import 'support/direct_rig.dart';

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  SyncEngine engine() => SyncEngine(
    store: rig.store,
    imap: rig.imap,
    accountId: rigAccountId,
    ownAddress: rigAddress,
    options: const SyncOptions(initialWindow: 10, prefetchBodies: 0),
  );

  test(
    'mail imported out of order does not make backfill skip anything',
    () async {
      rig = DirectRig();
      for (var i = 1; i <= 30; i++) {
        rig.imap.add('INBOX', rigMail('m$i', subject: 'Konu $i'));
      }
      final e = engine();
      await e.syncFolderList();
      final inbox = rig.store.folderByRole(rigAccountId, FolderRole.inbox)!;
      await e.syncFolder(inbox.folderId);
      expect(
        rig.store.uids(rigAccountId, inbox.folderId),
        List.generate(10, (i) => 21 + i),
      );

      // A search finds an old message and keeps it.
      final imported = await e.importMessages(inbox.folderId, [2, 25]);
      expect(imported, hasLength(1), reason: '25 was already stored');
      expect(rig.store.minUid(rigAccountId, inbox.folderId), 2);

      // Backfill still starts below what the first pass covered.
      await e.backfill(inbox.folderId, count: 10);
      expect(rig.store.uids(rigAccountId, inbox.folderId), [
        2,
        ...List.generate(20, (i) => 11 + i),
      ]);
      await e.backfill(inbox.folderId, count: 10);
      await e.backfill(inbox.folderId, count: 10);
      expect(
        rig.store.uids(rigAccountId, inbox.folderId),
        List.generate(30, (i) => 1 + i),
      );
      expect(
        rig.store.folder(rigAccountId, inbox.folderId)!.backfillComplete,
        isTrue,
      );
    },
  );

  test('an incremental pass does not move the frontier', () async {
    rig = DirectRig();
    for (var i = 1; i <= 15; i++) {
      rig.imap.add('INBOX', rigMail('m$i'));
    }
    final e = engine();
    await e.syncFolderList();
    final inbox = rig.store.folderByRole(rigAccountId, FolderRole.inbox)!;
    await e.syncFolder(inbox.folderId);
    final frontier = rig.store
        .folder(rigAccountId, inbox.folderId)!
        .oldestSyncedUid;
    await e.importMessages(inbox.folderId, [1]);
    rig.imap.add('INBOX', rigMail('m16'));
    await e.syncFolder(inbox.folderId);
    expect(
      rig.store.folder(rigAccountId, inbox.folderId)!.oldestSyncedUid,
      frontier,
    );
  });

  test('a renumbered folder refuses the import', () async {
    rig = DirectRig();
    for (var i = 1; i <= 3; i++) {
      rig.imap.add('INBOX', rigMail('m$i'));
    }
    final e = engine();
    await e.syncFolderList();
    final inbox = rig.store.folderByRole(rigAccountId, FolderRole.inbox)!;
    await e.syncFolder(inbox.folderId);
    rig.imap.changeUidValidity('INBOX', 999);
    await expectLater(
      e.importMessages(inbox.folderId, [9]),
      throwsA(isA<Exception>()),
    );
  });
}
