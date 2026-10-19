import 'dart:async';

import 'imap_models.dart';

/// Filters of a server-side search. Anything IMAP cannot express (attachment
/// presence, labels) is applied against the local store instead.
class RemoteSearchQuery {
  const RemoteSearchQuery({
    this.text,
    this.from,
    this.to,
    this.subject,
    this.since,
    this.before,
    this.unseen,
    this.flagged,
  });

  /// Matches anywhere in the message (`TEXT`).
  final String? text;
  final String? from;
  final String? to;
  final String? subject;
  final DateTime? since;
  final DateTime? before;
  final bool? unseen;
  final bool? flagged;

  bool get isEmpty =>
      (text ?? '').isEmpty &&
      (from ?? '').isEmpty &&
      (to ?? '').isEmpty &&
      (subject ?? '').isEmpty &&
      since == null &&
      before == null &&
      unseen == null &&
      flagged == null;
}

/// The IMAP operations the direct engine needs, in plain terms.
///
/// One instance talks to one account over one connection. Operations are not
/// concurrency-safe: callers (the engine) run them one at a time. Everything
/// above this interface (sync decisions, the local store, MIME handling) is
/// tested against an in-memory implementation; the real one is checked against
/// a live server.
///
/// Folder arguments are full IMAP paths. UIDs belong to the UIDVALIDITY that
/// the last [select] of that folder returned.
abstract interface class ImapService {
  /// Valid after [connect].
  ImapCapabilities get capabilities;

  bool get isConnected;

  /// Opens the connection, signs in **once** and reads the capabilities.
  /// Throws `DirectMailException` (never retries a failed sign-in).
  Future<void> connect();

  /// Closes the connection. Always safe to call.
  Future<void> disconnect();

  /// `NAMESPACE`, or null when the server has none.
  Future<RemoteNamespace?> namespace();

  Future<List<RemoteFolder>> listFolders();

  /// Selects [path] and reports its state.
  Future<RemoteFolderState> select(String path);

  /// State of [path] without selecting it (`STATUS`).
  Future<RemoteFolderState> status(String path);

  /// All UIDs of [path] in `[fromUid, toUid]` (open-ended when [toUid] is
  /// null), ascending. Pass `fromUid: 1` for every message.
  Future<List<int>> listUids(String path, {int fromUid = 1, int? toUid});

  /// Headers, flags, internal date and size of [uids].
  Future<List<RemoteMessage>> fetchHeaders(String path, List<int> uids);

  /// Flags of every message in `[fromUid, toUid]`.
  Future<List<RemoteFlags>> fetchFlags(
    String path, {
    required int fromUid,
    int? toUid,
  });

  /// Flags of messages changed after [modSeq]; only with CONDSTORE.
  Future<List<RemoteFlags>> fetchFlagsChangedSince(String path, int modSeq);

  /// The whole message: headers, body and attachments.
  Future<RemoteMessage> fetchFull(String path, int uid);

  /// Adds and removes flags on [uids] without echoing the result.
  Future<void> storeFlags(
    String path,
    List<int> uids, {
    Set<String> add = const {},
    Set<String> remove = const {},
  });

  Future<RemoteCopyResult> copy(String path, List<int> uids, String target);

  /// Moves with `MOVE`, or copy + delete when the server lacks it.
  Future<RemoteCopyResult> move(String path, List<int> uids, String target);

  /// Removes [uids] for good (`\Deleted` + expunge of exactly those UIDs).
  Future<void> expunge(String path, List<int> uids);

  /// Stores [source] (an RFC 5322 message) in [path].
  Future<RemoteAppendResult> append(
    String path,
    String source, {
    Set<String> flags = const {},
    DateTime? date,
  });

  Future<void> createFolder(String path);
  Future<void> renameFolder(String from, String to);
  Future<void> deleteFolder(String path);

  /// UIDs matching [query] in [path].
  Future<List<int>> search(String path, RemoteSearchQuery query);

  /// Mailbox quota, or null when the server has none.
  Future<RemoteQuota?> quota();

  /// Waits on [path] and reports what the server pushes. Cancelling the
  /// subscription ends the wait. Requires `capabilities.idle`.
  Stream<ImapPush> idle(String path);
}
