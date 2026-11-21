import 'dart:math';

import '../api_exception.dart';
import 'direct_errors.dart';
import 'direct_store.dart';
import 'imap_flags.dart';
import 'imap_models.dart';
import 'imap_service.dart';
import 'message_ingestor.dart';
import 'mime_processor.dart';

/// Tunables of a sync pass.
class SyncOptions {
  const SyncOptions({
    this.initialWindow = 100,
    this.headerBatch = 50,
    this.maxNewPerPass = 1000,
    this.hotFlagWindow = 500,
    this.prefetchBodies = 20,
    this.maxPrefetchBytes = 512 * 1024,
    this.useCondStore = false,
  });

  /// Newest messages fetched the first time a folder is synced.
  final int initialWindow;

  /// Messages per `FETCH`.
  final int headerBatch;

  /// Most new messages ingested in one pass; the rest follow on the next.
  final int maxNewPerPass;

  /// The newest this-many stored messages have their flags re-read on every
  /// pass; older ones only on a full pass.
  final int hotFlagWindow;

  /// Bodies fetched ahead for the newest new messages (previews, offline).
  final int prefetchBodies;
  final int maxPrefetchBytes;

  /// Use CONDSTORE `CHANGEDSINCE` to find flag changes. Off by default: it is
  /// exercised against the in-memory server but has not been proven on a
  /// real Dovecot yet.
  final bool useCondStore;
}

/// What one folder pass did.
class FolderSyncReport {
  /// Local ids of messages stored for the first time in this pass, in the
  /// order they were stored.
  final List<String> newLocalIds = [];
  int flagChanges = 0;
  int removed = 0;
  bool uidValidityChanged = false;

  /// The pass ran out of time or hit the per-pass cap; a later pass finishes.
  bool stoppedEarly = false;
  int remoteExists = 0;
}

/// Keeps the local copy of a folder in step with the server.
///
/// The algorithm needs nothing beyond IMAP4rev1 and a stable UID space
/// (RFC 3501 §2.3.1.1), and is the portable one of RFC 4549 §4.3:
///
/// * `UIDVALIDITY` changed → every stored UID is void; rows are detached and
///   re-bound by Message-ID so local annotations survive;
/// * `UIDNEXT` and `EXISTS` unchanged → nothing arrived or left, only flags
///   are looked at;
/// * otherwise new messages are the UIDs above the highest stored one, and
///   removed ones are stored UIDs the server no longer lists.
///
/// Every batch is committed on its own and the sync position only moves past
/// what was stored, so an interrupted pass resumes where it stopped and never
/// stores a message twice. The first sync and backfill work newest-first, so
/// being interrupted leaves a window of recent mail with older mail still to
/// come; new mail is taken oldest-first, so what is stored stays contiguous
/// above the previous highest UID.
class SyncEngine {
  SyncEngine({
    required this._store,
    required this._imap,
    required this.accountId,
    required this.ownAddress,
    this.options = const SyncOptions(),
  }) : _ingestor = MessageIngestor(_store);

  final DirectStore _store;
  final ImapService _imap;
  final MessageIngestor _ingestor;
  final String accountId;
  final String ownAddress;
  final SyncOptions options;

  Future<void> _ready() async {
    if (!_imap.isConnected) await _imap.connect();
  }

  // --- Folder list -----------------------------------------------------------

  /// Reads the folder tree and brings the stored one in line.
  Future<List<FolderRow>> syncFolderList() async {
    await _ready();
    final remote = await _imap.listFolders();
    _store.replaceFolders(accountId, remote);
    return _store.folders(accountId);
  }

  // --- One folder -----------------------------------------------------------------

  /// Syncs [folderId]. A [full] pass also re-reads the flags of old mail.
  /// [budget] stops the pass between batches once it is spent (background
  /// work); what was stored stays valid and the next pass continues.
  Future<FolderSyncReport> syncFolder(
    String folderId, {
    bool full = false,
    Duration? budget,
  }) async {
    final report = FolderSyncReport();
    final folder = _store.folder(accountId, folderId);
    if (folder == null || !folder.available || !folder.selectable) {
      return report;
    }
    final watch = Stopwatch()..start();
    bool outOfTime() => budget != null && watch.elapsed >= budget;

    try {
      await _ready();
      final state = await _imap.select(folder.path);

      if (folder.uidValidity != state.uidValidity) {
        _store.transaction(() {
          if (folder.uidValidity != null) {
            report.uidValidityChanged = true;
            _store.markFolderStale(accountId, folderId);
            _store.resetFolderSyncPosition(accountId, folderId);
          }
          _store.setFolderUidValidity(accountId, folderId, state.uidValidity);
        });
      }
      final current = _store.folder(accountId, folderId)!;
      final stale = {
        for (final m in _store.staleMessages(accountId, folderId))
          if (m.messageId.isNotEmpty) m.messageId: m.localId,
      };

      final localMax = _store.maxUid(accountId, folderId);
      final unchanged =
          !report.uidValidityChanged &&
          localMax != null &&
          state.uidNext == folder.uidNext &&
          state.exists == folder.remoteExists;

      bool? reachedStart;
      if (localMax == null) {
        reachedStart = await _firstSync(
          current,
          state,
          report,
          stale,
          outOfTime,
        );
      } else if (!unchanged) {
        await _ingestNew(current, localMax, report, stale, outOfTime);
        if (!outOfTime() && !report.stoppedEarly) {
          await _removeGone(current, report);
        }
      }

      if (outOfTime()) {
        report.stoppedEarly = true;
      } else {
        await _syncFlags(current, report, full: full);
      }
      await _prefetchBodies(report, outOfTime);

      if (!report.stoppedEarly) {
        // A mail this app moved here that the server still does not list
        // after a complete pass is not coming.
        _store.dropUnmatchedMoves(
          accountId,
          folderId,
          beforeMs:
              _store.now.millisecondsSinceEpoch -
              const Duration(minutes: 10).inMilliseconds,
        );
      }

      // The position only moves over a pass that finished; after an early
      // stop the old one stays so the next pass looks again.
      _store.recordFolderSync(
        accountId,
        folderId,
        uidValidity: state.uidValidity,
        uidNext: report.stoppedEarly ? (folder.uidNext ?? 0) : state.uidNext,
        exists: state.exists,
        unseen: state.unseen,
        highestModSeq: state.highestModSeq,
        // The frontier of what is known to be complete below the newest mail
        // is set by the first pass and by backfill only: mail imported out of
        // order (a search) lowers the lowest stored UID without making
        // anything in between known.
        oldestSyncedUid: reachedStart == null
            ? null
            : _store.minUid(accountId, folderId),
        backfillComplete: state.exists == 0
            ? true
            : (reachedStart == null
                  ? null
                  : reachedStart && !report.stoppedEarly),
      );
      report.remoteExists = state.exists;
      return report;
    } catch (error) {
      final mapped = DirectMailException.from(error);
      _store.recordFolderFailure(accountId, folderId, mapped.code ?? 'unknown');
      if (identical(mapped, error)) rethrow;
      throw mapped;
    }
  }

  /// Returns whether the window reached the start of the folder (nothing
  /// older is left to backfill).
  Future<bool> _firstSync(
    FolderRow folder,
    RemoteFolderState state,
    FolderSyncReport report,
    Map<String, String> stale,
    bool Function() outOfTime,
  ) async {
    if (state.exists == 0) return true;
    // Until this window is stored, older mail is not known to be complete:
    // a folder that was empty last time was marked done, and a pass
    // interrupted from here on must not leave it that way.
    _store.setFolderBackfillComplete(accountId, folder.folderId, false);
    final newest = await _newestUids(
      folder.path,
      options.initialWindow,
      top: state.uidNext - 1,
    );
    await _ingestBatches(
      folder,
      newest,
      report,
      stale,
      outOfTime,
      newestFirst: true,
    );
    return newest.length < options.initialWindow;
  }

  Future<void> _ingestNew(
    FolderRow folder,
    int localMax,
    FolderSyncReport report,
    Map<String, String> stale,
    bool Function() outOfTime,
  ) async {
    final fresh = await _imap.listUids(folder.path, fromUid: localMax + 1);
    if (fresh.isEmpty) return;
    final capped = fresh.length > options.maxNewPerPass
        ? fresh.sublist(0, options.maxNewPerPass)
        : fresh;
    if (capped.length < fresh.length) report.stoppedEarly = true;
    await _ingestBatches(
      folder,
      capped,
      report,
      stale,
      outOfTime,
      newestFirst: false,
    );
  }

  /// Newest-first discovery of at most [count] UIDs at or below [top],
  /// widening the searched range until enough are found, so a dense UID
  /// space costs one small `SEARCH` however big the folder is.
  Future<List<int>> _newestUids(
    String path,
    int count, {
    required int top,
  }) async {
    if (top < 1) return const [];
    var span = max(count * 4, 64);
    while (true) {
      final from = max(1, top - span + 1);
      final found = await _imap.listUids(path, fromUid: from, toUid: top);
      if (found.length >= count || from == 1) {
        found.sort();
        return found.length <= count
            ? found
            : found.sublist(found.length - count);
      }
      span *= 4;
    }
  }

  Future<void> _ingestBatches(
    FolderRow folder,
    List<int> uids,
    FolderSyncReport report,
    Map<String, String> stale,
    bool Function() outOfTime, {
    required bool newestFirst,
  }) async {
    final ordered = uids.toList()..sort();
    final batches = <List<int>>[
      for (var i = 0; i < ordered.length; i += options.headerBatch)
        ordered.sublist(i, min(i + options.headerBatch, ordered.length)),
    ];
    for (final batch in newestFirst ? batches.reversed : batches) {
      if (outOfTime()) {
        report.stoppedEarly = true;
        return;
      }
      final messages = await _imap.fetchHeaders(folder.path, batch);
      _store.transaction(() {
        for (final remote in messages) {
          final mime = remote.mime;
          final messageId = mime == null
              ? ''
              : MimeProcessor.parseHeaders(mime).messageId;
          final result = _ingestor.ingest(
            folder,
            remote,
            ownAddress: ownAddress,
            rebindLocalId: messageId.isEmpty ? null : stale.remove(messageId),
          );
          if (result.isNew) report.newLocalIds.add(result.localId);
        }
      });
    }
  }

  /// Stored messages the server no longer lists.
  Future<void> _removeGone(FolderRow folder, FolderSyncReport report) async {
    final lowest = _store.minUid(accountId, folder.folderId);
    if (lowest == null) return;
    final remote = (await _imap.listUids(folder.path, fromUid: lowest)).toSet();
    final gone = [
      for (final uid in _store.uids(
        accountId,
        folder.folderId,
        fromUid: lowest,
      ))
        if (!remote.contains(uid)) uid,
    ];
    if (gone.isEmpty) return;
    _store.deleteByUids(accountId, folder.folderId, gone);
    report.removed += gone.length;
  }

  /// Applies flag changes made elsewhere (another client, the server).
  Future<void> _syncFlags(
    FolderRow folder,
    FolderSyncReport report, {
    required bool full,
  }) async {
    final stored = _store.uids(accountId, folder.folderId);
    if (stored.isEmpty) return;

    final List<RemoteFlags> remote;
    final since = folder.highestModSeq;
    if (options.useCondStore &&
        !full &&
        since != null &&
        _imap.capabilities.condStore) {
      remote = await _imap.fetchFlagsChangedSince(folder.path, since);
    } else {
      final from = full || stored.length <= options.hotFlagWindow
          ? stored.first
          : stored[stored.length - options.hotFlagWindow];
      remote = await _imap.fetchFlags(folder.path, fromUid: from);
    }

    final local = _store.flagsByUid(accountId, folder.folderId);
    _store.transaction(() {
      for (final entry in remote) {
        final row = local[entry.uid];
        if (row == null) continue;
        final flags = ImapFlags.fromWire(entry.flags);
        if (flags.sameAs(
          isRead: row.isRead,
          isFlagged: row.isFlagged,
          isAnswered: row.isAnswered,
          isDraft: row.isDraft,
          isDeleted: row.isDeleted,
          isForwarded: row.isForwarded,
          keywords: row.keywords,
        )) {
          continue;
        }
        _store.updateFlags(
          accountId,
          row.localId,
          isRead: flags.isRead,
          isFlagged: flags.isFlagged,
          isAnswered: flags.isAnswered,
          isDraft: flags.isDraft,
          isForwarded: flags.isForwarded,
          isDeleted: flags.isDeleted,
          keywords: flags.keywords,
        );
        report.flagChanges++;
      }
    });
  }

  Future<void> _prefetchBodies(
    FolderSyncReport report,
    bool Function() outOfTime,
  ) async {
    if (options.prefetchBodies <= 0) return;
    final targets = [
      for (final id in report.newLocalIds.reversed)
        if (_store.message(accountId, id) case final m?)
          if (!m.bodyLoaded && m.size <= options.maxPrefetchBytes) m,
    ].take(options.prefetchBodies).toList();
    for (final message in targets) {
      if (outOfTime()) return;
      try {
        await ensureBody(message.localId);
      } on DirectMailException catch (error) {
        // One body that cannot be fetched now is fetched when it is opened,
        // but a lost connection ends the pass.
        if (error.category == ApiErrorCategory.network ||
            error.category == ApiErrorCategory.timeout ||
            error.category == ApiErrorCategory.authentication) {
          rethrow;
        }
      }
    }
  }

  // --- Bodies -------------------------------------------------------------------------

  /// Fetches and stores the body of [localId] if it is not stored yet.
  Future<void> ensureBody(String localId, {bool force = false}) async {
    final row = _store.message(accountId, localId);
    if (row == null || row.uid == null) {
      throw DirectMailException(DirectErrorKind.mailNotFound);
    }
    if (row.bodyLoaded && !force) return;
    final folder = _store.folder(accountId, row.folderId);
    if (folder == null) {
      throw DirectMailException(DirectErrorKind.folderNotFound);
    }
    await _ready();
    await _imap.select(folder.path);
    final full = await _imap.fetchFull(folder.path, row.uid!);
    final mime = full.mime;
    if (mime == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    final processed = MimeProcessor.processBody(mime);
    _store.saveBody(
      accountId,
      localId,
      BodyDraft(
        text: processed.text,
        html: processed.html.html.isEmpty ? null : processed.html.html,
        hasRemoteContent: processed.html.hasRemoteContent,
        remoteHosts: processed.html.remoteHosts,
        remoteImageHosts: processed.html.remoteImageHosts,
        trackingHosts: processed.html.trackingPixelHosts,
        authJson: processed.authenticationJson,
        securityJson: processed.securityJson,
        listUnsubscribe: processed.listUnsubscribe,
        listUnsubscribePost: processed.listUnsubscribePost,
        receiptTo: processed.receiptTo,
        snippet: processed.snippet,
      ),
      processed.parts,
    );
  }

  // --- Single messages ------------------------------------------------------------------

  /// Stores the messages [uids] of [folderId] without touching the sync
  /// position: search results from anywhere in the folder. The ones already
  /// stored are left as they are. Returns the local ids of the new ones.
  ///
  /// With [withBodies] the text of each of them, new or already stored
  /// without it, is fetched too (messages over [maxBodyBytes] keep their
  /// headers only): a server search matches text inside messages, and the
  /// device can only find them again by it if it holds that text.
  Future<List<String>> importMessages(
    String folderId,
    List<int> uids, {
    bool withBodies = false,
    int maxBodyBytes = 5 * 1024 * 1024,
  }) async {
    final folder = _store.folder(accountId, folderId);
    if (folder == null || !folder.available || !folder.selectable) {
      return const [];
    }
    final stored = _store.uids(accountId, folderId).toSet();
    final fresh = [
      for (final uid in uids)
        if (!stored.contains(uid)) uid,
    ];
    final known = [
      for (final uid in uids)
        if (stored.contains(uid)) uid,
    ];
    if (fresh.isEmpty && (!withBodies || known.isEmpty)) return const [];
    await _ready();
    final state = await _imap.select(folder.path);
    if (folder.uidValidity != null && state.uidValidity != folder.uidValidity) {
      throw DirectMailException(DirectErrorKind.mailboxChanged);
    }
    final report = FolderSyncReport();
    if (fresh.isNotEmpty) {
      await _ingestBatches(
        folder,
        fresh,
        report,
        <String, String>{},
        () => false,
        newestFirst: true,
      );
    }
    if (withBodies) {
      final wanted = [
        ...report.newLocalIds,
        for (final uid in known)
          if (_store.messageByUid(accountId, folderId, uid) case final row?)
            if (!row.bodyLoaded) row.localId,
      ];
      for (final localId in wanted) {
        final row = _store.message(accountId, localId);
        if (row == null || (row.size > 0 && row.size > maxBodyBytes)) continue;
        try {
          await ensureBody(localId);
        } on DirectMailException catch (error) {
          if (error.kind != DirectErrorKind.mailNotFound) rethrow;
        }
      }
    }
    return report.newLocalIds;
  }

  // --- Older mail ---------------------------------------------------------------------------

  /// Fetches up to [count] messages older than the oldest stored one.
  /// Returns how many were stored.
  Future<int> backfill(String folderId, {required int count}) async {
    final folder = _store.folder(accountId, folderId);
    if (folder == null || folder.backfillComplete || !folder.selectable) {
      return 0;
    }
    final oldest = folder.oldestSyncedUid ?? _store.minUid(accountId, folderId);
    if (oldest == null) return 0;
    await _ready();
    await _imap.select(folder.path);
    final older = await _newestUids(folder.path, count, top: oldest - 1);
    final report = FolderSyncReport();
    await _ingestBatches(
      folder,
      older,
      report,
      <String, String>{},
      () => false,
      newestFirst: true,
    );
    _store.recordFolderSync(
      accountId,
      folderId,
      uidValidity: folder.uidValidity ?? 0,
      uidNext: folder.uidNext ?? 0,
      exists: folder.remoteExists ?? 0,
      oldestSyncedUid: older.isEmpty ? null : older.first,
      backfillComplete: older.length < count,
    );
    return report.newLocalIds.length;
  }
}
