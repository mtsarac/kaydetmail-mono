import 'dart:async';

import 'package:enough_mail_plus/enough_mail.dart' show MimeMessage;
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/imap_service.dart';

/// One message in the fake mailbox.
class FakeMessage {
  FakeMessage(this.uid, this.raw, this.flags, this.internalDate);

  final int uid;
  final String raw;
  final Set<String> flags;
  final DateTime internalDate;
  int modSeq = 0;
}

class FakeFolder {
  FakeFolder(
    this.path, {
    this.delimiter = '/',
    this.specialUse,
    this.uidValidity = 100,
  });

  final String path;
  final String delimiter;
  final FolderRole? specialUse;
  int uidValidity;
  int uidNext = 1;
  int highestModSeq = 1;
  final Map<int, FakeMessage> messages = {};
  final Set<int> vanished = {};
}

/// An in-memory IMAP server behind [ImapService], for tests of everything
/// above the wire: it answers like a server would (UIDs only grow, expunged
/// UIDs are never reused, UIDVALIDITY can change) and counts the calls it
/// gets so tests can assert how much work a sync did.
class FakeImapService implements ImapService {
  FakeImapService({
    Set<String> capabilities = const {
      'IMAP4REV1',
      'IDLE',
      'UIDPLUS',
      'MOVE',
      'NAMESPACE',
      'UNSELECT',
    },
    this.namespacePrefix = '',
    this.delimiter = '/',
  }) : _capabilities = ImapCapabilities.fromNames(capabilities);

  ImapCapabilities _capabilities;
  final String namespacePrefix;
  final String delimiter;
  final Map<String, FakeFolder> folders = {};
  bool _connected = false;
  int _clock = 0;

  /// Calls received, by operation name.
  final Map<String, int> calls = {};
  final List<String> log = [];

  /// Errors to throw for the next call(s) of an operation.
  final Map<String, List<Object>> _failures = {};

  /// Pushes seen by [idle]; tests add to it.
  final StreamController<ImapPush> pushes =
      StreamController<ImapPush>.broadcast();

  void setCapabilities(Set<String> names) =>
      _capabilities = ImapCapabilities.fromNames(names);

  void failNext(String operation, Object error, {int times = 1}) => _failures
      .putIfAbsent(operation, () => [])
      .addAll(List.filled(times, error));

  /// Throws [error] on the [n]th call of [operation] from now (1 = the next).
  void failOnNthCall(String operation, int n, Object error) {
    _scheduled[operation] = (calls[operation] ?? 0) + n;
    _scheduledErrors[operation] = error;
  }

  final Map<String, int> _scheduled = {};
  final Map<String, Object> _scheduledErrors = {};

  int count(String operation) => calls[operation] ?? 0;
  void resetCalls() {
    calls.clear();
    log.clear();
  }

  void _enter(String op, [String? detail]) {
    calls[op] = (calls[op] ?? 0) + 1;
    log.add(detail == null ? op : '$op $detail');
    final pending = _failures[op];
    if (pending != null && pending.isNotEmpty) throw pending.removeAt(0);
    if (_scheduled[op] == calls[op]) {
      _scheduled.remove(op);
      throw _scheduledErrors.remove(op)!;
    }
  }

  // --- Test controls ---------------------------------------------------------------

  FakeFolder addFolder(String path, {FolderRole? use, int uidValidity = 100}) =>
      folders[path] = FakeFolder(
        path,
        delimiter: delimiter,
        specialUse: use,
        uidValidity: uidValidity,
      );

  /// Delivers [raw] into [path] and returns its UID.
  int add(
    String path,
    String raw, {
    Set<String> flags = const {},
    DateTime? date,
  }) {
    final folder = folders[path]!;
    final uid = folder.uidNext++;
    final when =
        date ?? DateTime.utc(2025, 1, 1).add(Duration(minutes: ++_clock));
    final message = FakeMessage(uid, raw, {...flags}, when)
      ..modSeq = ++folder.highestModSeq;
    folder.messages[uid] = message;
    return uid;
  }

  void remove(String path, int uid) {
    final folder = folders[path]!;
    if (folder.messages.remove(uid) != null) {
      folder.vanished.add(uid);
      folder.highestModSeq++;
    }
  }

  void setFlags(String path, int uid, Set<String> flags) {
    final folder = folders[path]!;
    final m = folder.messages[uid]!;
    m.flags
      ..clear()
      ..addAll(flags);
    m.modSeq = ++folder.highestModSeq;
  }

  /// The server renumbers a folder: every UID is meaningless afterwards.
  void changeUidValidity(String path, int newValidity) {
    final folder = folders[path]!;
    final old = folder.messages.values.toList();
    folder
      ..uidValidity = newValidity
      ..messages.clear()
      ..vanished.clear()
      ..uidNext = 1;
    for (final m in old) {
      add(path, m.raw, flags: m.flags, date: m.internalDate);
    }
  }

  List<int> uidsOf(String path) =>
      (folders[path]!.messages.keys.toList()..sort());

  // --- ImapService -------------------------------------------------------------------

  @override
  ImapCapabilities get capabilities => _capabilities;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    _enter('connect');
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    calls['disconnect'] = (calls['disconnect'] ?? 0) + 1;
    _connected = false;
  }

  @override
  Future<RemoteNamespace?> namespace() async {
    _enter('namespace');
    if (!_capabilities.namespace) return null;
    return RemoteNamespace(
      personalPrefix: namespacePrefix,
      delimiter: delimiter,
    );
  }

  @override
  Future<List<RemoteFolder>> listFolders() async {
    _enter('listFolders');
    return [
      for (final f in folders.values)
        RemoteFolder(
          path: f.path,
          name: f.delimiter.isEmpty ? f.path : f.path.split(f.delimiter).last,
          delimiter: f.delimiter,
          specialUse: f.specialUse,
        ),
    ];
  }

  FakeFolder _folder(String path) {
    final f = folders[path];
    if (f == null) {
      throw DirectMailException(DirectErrorKind.folderNotFound);
    }
    return f;
  }

  RemoteFolderState _stateOf(FakeFolder f) => RemoteFolderState(
    uidValidity: f.uidValidity,
    uidNext: f.uidNext,
    exists: f.messages.length,
    highestModSeq: _capabilities.condStore ? f.highestModSeq : null,
    unseen: f.messages.values.where((m) => !m.flags.contains(r'\Seen')).length,
  );

  @override
  Future<RemoteFolderState> select(String path) async {
    _enter('select', path);
    return _stateOf(_folder(path));
  }

  @override
  Future<RemoteFolderState> status(String path) async {
    _enter('status', path);
    return _stateOf(_folder(path));
  }

  @override
  Future<List<int>> listUids(String path, {int fromUid = 1, int? toUid}) async {
    _enter('listUids', '$path $fromUid:${toUid ?? '*'}');
    final folder = _folder(path);
    return (folder.messages.keys
        .where((u) => u >= fromUid && (toUid == null || u <= toUid))
        .toList()
      ..sort());
  }

  MimeMessage _headersOnly(String raw) {
    final end = raw.indexOf('\r\n\r\n');
    return MimeMessage.parseFromText(end < 0 ? raw : raw.substring(0, end + 4));
  }

  @override
  Future<List<RemoteMessage>> fetchHeaders(String path, List<int> uids) async {
    _enter('fetchHeaders', '$path ${uids.length}');
    final folder = _folder(path);
    return [
      for (final uid in uids)
        if (folder.messages[uid] case final m?)
          RemoteMessage(
            uid: uid,
            flags: {...m.flags},
            internalDate: m.internalDate,
            size: m.raw.length,
            mime: _headersOnly(m.raw),
          ),
    ];
  }

  @override
  Future<List<RemoteFlags>> fetchFlags(
    String path, {
    required int fromUid,
    int? toUid,
  }) async {
    _enter('fetchFlags', '$path $fromUid:${toUid ?? '*'}');
    final folder = _folder(path);
    return [
      for (final m in folder.messages.values)
        if (m.uid >= fromUid && (toUid == null || m.uid <= toUid))
          RemoteFlags(m.uid, {...m.flags}),
    ];
  }

  @override
  Future<List<RemoteFlags>> fetchFlagsChangedSince(
    String path,
    int modSeq,
  ) async {
    _enter('fetchFlagsChangedSince', '$path $modSeq');
    if (!_capabilities.condStore) {
      throw DirectMailException(DirectErrorKind.capabilityMissing);
    }
    final folder = _folder(path);
    return [
      for (final m in folder.messages.values)
        if (m.modSeq > modSeq) RemoteFlags(m.uid, {...m.flags}),
    ];
  }

  @override
  Future<RemoteMessage> fetchFull(String path, int uid) async {
    _enter('fetchFull', '$path $uid');
    final m = _folder(path).messages[uid];
    if (m == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    return RemoteMessage(
      uid: uid,
      flags: {...m.flags},
      internalDate: m.internalDate,
      size: m.raw.length,
      mime: MimeMessage.parseFromText(m.raw),
    );
  }

  @override
  Future<void> storeFlags(
    String path,
    List<int> uids, {
    Set<String> add = const {},
    Set<String> remove = const {},
  }) async {
    _enter('storeFlags', '$path $uids +$add -$remove');
    final folder = _folder(path);
    for (final uid in uids) {
      final m = folder.messages[uid];
      if (m == null) continue;
      m.flags
        ..addAll(add)
        ..removeAll(remove);
      m.modSeq = ++folder.highestModSeq;
    }
  }

  RemoteCopyResult _copyTo(String path, List<int> uids, String target) {
    final from = _folder(path);
    final to = _folder(target);
    final sources = <int>[];
    final targets = <int>[];
    for (final uid in uids) {
      final m = from.messages[uid];
      if (m == null) continue;
      sources.add(uid);
      targets.add(add(target, m.raw, flags: m.flags, date: m.internalDate));
    }
    return _capabilities.uidPlus
        ? RemoteCopyResult(
            uidValidity: to.uidValidity,
            sourceUids: sources,
            targetUids: targets,
          )
        : const RemoteCopyResult();
  }

  @override
  Future<RemoteCopyResult> copy(
    String path,
    List<int> uids,
    String target,
  ) async {
    _enter('copy', '$path $uids -> $target');
    return _copyTo(path, uids, target);
  }

  @override
  Future<RemoteCopyResult> move(
    String path,
    List<int> uids,
    String target,
  ) async {
    _enter('move', '$path $uids -> $target');
    final result = _copyTo(path, uids, target);
    for (final uid in uids) {
      remove(path, uid);
    }
    return result;
  }

  @override
  Future<void> expunge(String path, List<int> uids) async {
    _enter('expunge', '$path $uids');
    for (final uid in uids) {
      remove(path, uid);
    }
  }

  @override
  Future<RemoteAppendResult> append(
    String path,
    String source, {
    Set<String> flags = const {},
    DateTime? date,
  }) async {
    _enter('append', path);
    final folder = _folder(path);
    final uid = add(path, source, flags: flags, date: date);
    return _capabilities.uidPlus
        ? RemoteAppendResult(uidValidity: folder.uidValidity, uid: uid)
        : const RemoteAppendResult();
  }

  @override
  Future<void> createFolder(String path) async {
    _enter('createFolder', path);
    if (folders.containsKey(path)) {
      throw DirectMailException(DirectErrorKind.imapCommandFailed);
    }
    addFolder(path);
  }

  /// Makes the next rename land somewhere other than asked, like a server
  /// that reads a new name relative to the old folder's parent.
  String Function(String from, String to)? renameLandsAt;

  @override
  Future<void> renameFolder(String from, String requested) async {
    _enter('renameFolder', '$from -> $requested');
    final to = renameLandsAt?.call(from, requested) ?? requested;
    renameLandsAt = null;
    final old = _folder(from);
    // Like a real server (RFC 3501 §6.3.5): everything below moves with it.
    final affected = [
      for (final f in folders.values)
        if (f.path == from ||
            (old.delimiter.isNotEmpty &&
                f.path.startsWith('$from${old.delimiter}')))
          f,
    ];
    for (final f in affected) {
      folders.remove(f.path);
      final path = f.path == from ? to : to + f.path.substring(from.length);
      folders[path] =
          FakeFolder(
              path,
              delimiter: f.delimiter,
              specialUse: f.specialUse,
              uidValidity: f.uidValidity,
            )
            ..uidNext = f.uidNext
            ..highestModSeq = f.highestModSeq
            ..messages.addAll(f.messages);
    }
  }

  @override
  Future<void> deleteFolder(String path) async {
    _enter('deleteFolder', path);
    _folder(path);
    folders.remove(path);
  }

  @override
  Future<List<int>> search(String path, RemoteSearchQuery query) async {
    _enter('search', path);
    final folder = _folder(path);
    bool contains(String haystack, String? needle) =>
        needle == null ||
        needle.isEmpty ||
        haystack.toLowerCase().contains(needle.toLowerCase());
    return [
      for (final m in folder.messages.values)
        if (contains(m.raw, query.text) &&
            contains(m.raw, query.from) &&
            (query.unseen == null ||
                query.unseen == !m.flags.contains(r'\Seen')) &&
            (query.flagged == null ||
                query.flagged == m.flags.contains(r'\Flagged')))
          m.uid,
    ]..sort();
  }

  @override
  Future<RemoteQuota?> quota() async {
    _enter('quota');
    return null;
  }

  @override
  Stream<ImapPush> idle(String path) {
    _enter('idle', path);
    return pushes.stream;
  }
}
