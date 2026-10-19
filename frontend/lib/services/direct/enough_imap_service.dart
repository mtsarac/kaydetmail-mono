import 'dart:async';
import 'dart:io';

import 'package:enough_mail_plus/enough_mail.dart'
    hide MailAccount, MailAuthentication;

import '../api_auth_service.dart' show MailSecurity;
import 'direct_account_setup.dart';
import 'direct_errors.dart';
import 'imap_models.dart';
import 'imap_service.dart';

/// How the connection is secured. Only [tls] and [startTls] are reachable
/// from an account; [plaintext] exists so tests can talk to a local server.
enum ImapTransport { tls, startTls, plaintext }

/// [ImapService] over `enough_mail_plus`.
///
/// One instance owns one connection. The account is signed in exactly once
/// per connection and a refused sign-in is never retried (see
/// [classifyLoginFailure]); every library or socket failure leaves here as a
/// [DirectMailException], never as raw protocol text.
class EnoughImapService implements ImapService {
  EnoughImapService({
    required DirectEndpoint endpoint,
    required this._password,
    ImapTransport? transport,
    this._onBadCertificate,
    this.connectTimeout = const Duration(seconds: 20),
    this.responseTimeout = const Duration(seconds: 45),
  }) : _endpoint = endpoint,
       _transport =
           transport ??
           (endpoint.security == MailSecurity.startTls
               ? ImapTransport.startTls
               : ImapTransport.tls);

  final DirectEndpoint _endpoint;
  final String _password;
  final ImapTransport _transport;
  final bool Function(X509Certificate)? _onBadCertificate;
  final Duration connectTimeout;
  final Duration responseTimeout;

  ImapClient? _client;
  ImapCapabilities _capabilities = const ImapCapabilities({});
  String? _selectedPath;
  final Map<String, Mailbox> _mailboxes = {};

  @override
  ImapCapabilities get capabilities => _capabilities;

  @override
  bool get isConnected => _client?.isConnected ?? false;

  ImapClient get _c {
    final client = _client;
    if (client == null || !client.isConnected) {
      throw DirectMailException(DirectErrorKind.offline);
    }
    return client;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DirectMailException {
      rethrow;
    } on ImapException catch (error) {
      throw classifyImapFailure(error);
    } catch (error) {
      throw DirectMailException.from(error);
    }
  }

  // --- Connection ---------------------------------------------------------------

  @override
  Future<void> connect() async {
    await disconnect();
    final client = ImapClient(
      isLogEnabled: false,
      defaultResponseTimeout: responseTimeout,
      onBadCertificate: _onBadCertificate,
    );
    try {
      await client
          .connectToServer(
            _endpoint.host,
            _endpoint.port,
            isSecure: _transport == ImapTransport.tls,
            timeout: connectTimeout,
          )
          .timeout(connectTimeout + const Duration(seconds: 5));
      if (_transport == ImapTransport.startTls) await client.startTls();
    } on ImapException catch (error) {
      await _quietClose(client);
      throw classifyImapFailure(error);
    } catch (error) {
      await _quietClose(client);
      throw DirectMailException.from(error);
    }

    // Signed in once. A refusal is final until the user changes something.
    try {
      await client.login(_endpoint.username, _password);
    } on ImapException catch (error) {
      await _quietClose(client);
      throw classifyLoginFailure(error);
    } catch (error) {
      await _quietClose(client);
      throw DirectMailException.from(error);
    }

    _client = client;
    try {
      final caps = await client.capability();
      _capabilities = ImapCapabilities.fromNames(caps.map((c) => c.name));
    } on Object catch (error) {
      await _quietClose(client);
      _client = null;
      throw DirectMailException.from(error);
    }
    _selectedPath = null;
  }

  Future<void> _quietClose(ImapClient client) async {
    try {
      await client.disconnect();
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    _selectedPath = null;
    _mailboxes.clear();
    if (client == null) return;
    try {
      if (client.isConnected && client.isLoggedIn) {
        await client.logout().timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      // Closing must never fail.
    }
    await _quietClose(client);
  }

  /// A signed-in connection that failed to sign in again is the server
  /// telling us something; failures here map like any other command's.
  static DirectMailException classifyLoginFailure(ImapException error) {
    final text = '${error.message} ${error.details}'.toLowerCase();
    if (_mentions(text, const [
      'application-specific password',
      'app password',
      'app-specific password',
      'web login required',
      'less secure',
      'application password',
    ])) {
      return DirectMailException(
        DirectErrorKind.authRequiresAppPassword,
        cause: error,
      );
    }
    if (_mentions(text, const [
      '[unavailable]',
      '[inuse]',
      'too many',
      'try again later',
      'temporarily',
      'rate limit',
      '[limit]',
    ])) {
      return DirectMailException(
        _mentions(text, const ['too many', 'rate limit', '[limit]'])
            ? DirectErrorKind.rateLimited
            : DirectErrorKind.temporaryFailure,
        cause: error,
      );
    }
    if (_mentions(text, const ['logindisabled', 'starttls', 'tls required'])) {
      return DirectMailException(
        DirectErrorKind.tlsHandshakeFailed,
        cause: error,
      );
    }
    return DirectMailException(DirectErrorKind.authFailed, cause: error);
  }

  /// Maps a failed command (not a sign-in) to a user-facing kind.
  static DirectMailException classifyImapFailure(ImapException error) {
    final text = '${error.message} ${error.details}'.toLowerCase();
    DirectErrorKind kind = DirectErrorKind.imapCommandFailed;
    if (_mentions(text, const [
      '[nonexistent]',
      '[trycreate]',
      'no such mailbox',
      "doesn't exist",
      'does not exist',
      'mailbox not found',
      'unknown mailbox',
    ])) {
      kind = DirectErrorKind.folderNotFound;
    } else if (_mentions(text, const [
      '[overquota]',
      'over quota',
      'quota exceeded',
    ])) {
      kind = DirectErrorKind.quotaExceeded;
    } else if (_mentions(text, const ['[limit]', 'too many', 'rate limit'])) {
      kind = DirectErrorKind.rateLimited;
    } else if (_mentions(text, const [
      '[unavailable]',
      '[inuse]',
      'try again later',
      'temporarily',
      'server busy',
    ])) {
      kind = DirectErrorKind.temporaryFailure;
    } else if (_mentions(text, const [
      '[authenticationfailed]',
      '[authorizationfailed]',
      'authentication failed',
    ])) {
      kind = DirectErrorKind.authFailed;
    } else if (_mentions(text, const [
      'connection closed',
      'not connected',
      'socket',
    ])) {
      kind = DirectErrorKind.hostUnreachable;
    }
    return DirectMailException(kind, cause: error);
  }

  static bool _mentions(String text, List<String> needles) =>
      needles.any(text.contains);

  // --- Folders --------------------------------------------------------------------

  @override
  Future<RemoteNamespace?> namespace() => _guard(() async {
    if (!_capabilities.namespace) return null;
    final response = await _c.namespace();
    final personal = response?.personal.firstOrNull;
    if (personal == null) return null;
    return RemoteNamespace(
      personalPrefix: personal.prefix,
      delimiter: personal.delimiter ?? '',
    );
  });

  @override
  Future<List<RemoteFolder>> listFolders() => _guard(() async {
    await _refreshMailboxes();
    return [
      for (final box in _mailboxes.values)
        RemoteFolder(
          path: box.path,
          name: box.name,
          delimiter: box.pathSeparator,
          attributes: {
            for (final flag in box.flags)
              switch (flag) {
                MailboxFlag.noSelect => r'\noselect',
                MailboxFlag.hasChildren => r'\haschildren',
                MailboxFlag.hasNoChildren => r'\hasnochildren',
                MailboxFlag.nonExistent => r'\nonexistent',
                MailboxFlag.subscribed => r'\subscribed',
                _ => flag.name.toLowerCase(),
              },
          },
          specialUse: box.isInbox
              ? FolderRole.inbox
              : box.isSent
              ? FolderRole.sent
              : box.isDrafts
              ? FolderRole.drafts
              : box.isTrash
              ? FolderRole.trash
              : box.isJunk
              ? FolderRole.junk
              : box.isArchive
              ? FolderRole.archive
              : null,
        ),
    ];
  });

  Future<void> _refreshMailboxes() async {
    final boxes = await _c.listMailboxes(recursive: true);
    _mailboxes
      ..clear()
      ..addEntries(boxes.map((box) => MapEntry(box.path, box)));
  }

  /// The library's own object for [path] (it carries the modified-UTF-7
  /// name the server expects), found by listing when not yet known.
  Future<Mailbox> _mailbox(String path) async {
    var box = _mailboxes[path];
    if (box == null) {
      await _refreshMailboxes();
      box = _mailboxes[path];
    }
    if (box == null) throw DirectMailException(DirectErrorKind.folderNotFound);
    return box;
  }

  Future<Mailbox> _select(String path) async {
    final box = await _c.selectMailboxByPath(path);
    _selectedPath = path;
    return box;
  }

  /// Deselects [path] if it is the selected folder, without the implicit
  /// expunge that `CLOSE` performs on `\Deleted` mail.
  Future<void> _leave(String path) async {
    if (_selectedPath != path) return;
    if (_capabilities.unselect) {
      await _c.unselectMailbox();
      _selectedPath = null;
    }
  }

  Future<void> _ensureSelected(String path) async {
    if (_selectedPath == path && _c.isConnected) return;
    await _select(path);
  }

  RemoteFolderState _state(Mailbox box, {int? unseen}) => RemoteFolderState(
    uidValidity: box.uidValidity ?? 0,
    uidNext: box.uidNext ?? 1,
    exists: box.messagesExists,
    highestModSeq: box.highestModSequence,
    unseen: unseen ?? box.messagesUnseen,
  );

  @override
  Future<RemoteFolderState> select(String path) => _guard(() async {
    final box = await _select(path);
    // The unread count is not part of SELECT. STATUS on the selected folder
    // is discouraged by the RFC but answered by every server we know; a
    // refusal only costs the count.
    int? unseen;
    try {
      final status = await _c.statusMailbox(box, [StatusFlags.unseen]);
      unseen = status.messagesUnseen;
    } catch (_) {}
    return _state(box, unseen: unseen);
  });

  @override
  Future<RemoteFolderState> status(String path) => _guard(() async {
    final box = await _c.statusMailbox(await _mailbox(path), [
      StatusFlags.messages,
      StatusFlags.uidNext,
      StatusFlags.uidValidity,
      StatusFlags.unseen,
      if (_capabilities.condStore) StatusFlags.highestModSequence,
    ]);
    return _state(box);
  });

  // --- Reading ----------------------------------------------------------------------

  /// UIDs in `[fromUid, toUid]`. A range such as `500:*` makes servers return
  /// the highest message even when it lies below 500 (RFC 3501 §9: `*` is
  /// the largest number in use), so the answer is filtered again here.
  @override
  Future<List<int>> listUids(String path, {int fromUid = 1, int? toUid}) =>
      _guard(() async {
        await _ensureSelected(path);
        final range = '$fromUid:${toUid ?? '*'}';
        final result = await _c.uidSearchMessages(searchCriteria: 'UID $range');
        return [
          for (final uid in result.matchingSequence?.toList() ?? const <int>[])
            if (uid >= fromUid && (toUid == null || uid <= toUid)) uid,
        ]..sort();
      });

  static const _headerItems =
      '(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER])';

  @override
  Future<List<RemoteMessage>> fetchHeaders(String path, List<int> uids) =>
      _guard(() async {
        if (uids.isEmpty) return const [];
        await _ensureSelected(path);
        final result = await _c.uidFetchMessages(
          MessageSequence.fromIds(uids, isUid: true),
          _headerItems,
        );
        return [for (final m in result.messages) ?_remote(m)];
      });

  RemoteMessage? _remote(MimeMessage m) {
    final uid = m.uid;
    if (uid == null) return null;
    return RemoteMessage(
      uid: uid,
      flags: {...?m.flags},
      internalDate: parseInternalDate(m.internalDate),
      size: m.size,
      mime: m,
    );
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12, //
  };

  /// Reads an IMAP `INTERNALDATE` (`dd-Mon-yyyy HH:MM:SS +zzzz`, RFC 3501
  /// date-time) as UTC; null when it is not in that form.
  static DateTime? parseInternalDate(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^\s*(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\s*$',
    ).firstMatch(value);
    final month = match == null ? null : _months[match.group(2)!.toLowerCase()];
    if (match == null || month == null) return null;
    final local = DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
    final offset = Duration(
      hours: int.parse(match.group(8)!),
      minutes: int.parse(match.group(9)!),
    );
    return match.group(7) == '-' ? local.add(offset) : local.subtract(offset);
  }

  @override
  Future<List<RemoteFlags>> fetchFlags(
    String path, {
    required int fromUid,
    int? toUid,
  }) => _guard(() async {
    await _ensureSelected(path);
    final sequence = toUid == null
        ? MessageSequence.fromRangeToLast(fromUid, isUidSequence: true)
        : MessageSequence.fromRange(fromUid, toUid, isUidSequence: true);
    final result = await _c.uidFetchMessages(sequence, '(UID FLAGS)');
    return [
      for (final m in result.messages)
        if (m.uid case final uid? when uid >= fromUid)
          RemoteFlags(uid, {...?m.flags}),
    ];
  });

  @override
  Future<List<RemoteFlags>> fetchFlagsChangedSince(String path, int modSeq) =>
      _guard(() async {
        if (!_capabilities.condStore) {
          throw DirectMailException(DirectErrorKind.capabilityMissing);
        }
        await _ensureSelected(path);
        final result = await _c.uidFetchMessages(
          MessageSequence.fromRangeToLast(1, isUidSequence: true),
          '(UID FLAGS)',
          changedSinceModSequence: modSeq,
        );
        return [
          for (final m in result.messages)
            if (m.uid case final uid?) RemoteFlags(uid, {...?m.flags}),
        ];
      });

  @override
  Future<RemoteMessage> fetchFull(String path, int uid) => _guard(() async {
    await _ensureSelected(path);
    final result = await _c.uidFetchMessage(
      uid,
      '(UID FLAGS INTERNALDATE BODY.PEEK[])',
    );
    final remote = result.messages.isEmpty
        ? null
        : _remote(result.messages.first);
    if (remote == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    return remote;
  });

  // --- Changing -----------------------------------------------------------------------

  @override
  Future<void> storeFlags(
    String path,
    List<int> uids, {
    Set<String> add = const {},
    Set<String> remove = const {},
  }) => _guard(() async {
    if (uids.isEmpty) return;
    await _ensureSelected(path);
    final sequence = MessageSequence.fromIds(uids, isUid: true);
    if (add.isNotEmpty) {
      await _c.uidStore(
        sequence,
        add.toList(),
        action: StoreAction.add,
        silent: true,
      );
    }
    if (remove.isNotEmpty) {
      await _c.uidStore(
        sequence,
        remove.toList(),
        action: StoreAction.remove,
        silent: true,
      );
    }
  });

  RemoteCopyResult _copyResult(GenericImapResult result) {
    final code = result.responseCodeCopyUid;
    if (code == null) return const RemoteCopyResult();
    return RemoteCopyResult(
      uidValidity: code.uidValidity,
      sourceUids: code.originalSequence?.toList(),
      targetUids: code.targetSequence.toList(),
    );
  }

  @override
  Future<RemoteCopyResult> copy(String path, List<int> uids, String target) =>
      _guard(() async {
        await _ensureSelected(path);
        final result = await _c.uidCopy(
          MessageSequence.fromIds(uids, isUid: true),
          targetMailboxPath: target,
        );
        return _copyResult(result);
      });

  /// Moves [uids]. With UIDPLUS the move is a copy (whose `COPYUID` names the
  /// new UIDs) followed by removing exactly the originals: `MOVE` reports the
  /// new UIDs in an untagged response that the library does not hand back, and
  /// the caller needs them to keep the message's identity. A crash between
  /// the two steps leaves a duplicate, never a loss. Without UIDPLUS, `MOVE`
  /// is used when offered (the new UIDs are then unknown to the caller), and
  /// otherwise copy + removal.
  @override
  Future<RemoteCopyResult> move(String path, List<int> uids, String target) =>
      _guard(() async {
        await _ensureSelected(path);
        final sequence = MessageSequence.fromIds(uids, isUid: true);
        if (!_capabilities.uidPlus && _capabilities.move) {
          await _c.uidMove(sequence, targetMailboxPath: target);
          return const RemoteCopyResult();
        }
        final copied = await _c.uidCopy(sequence, targetMailboxPath: target);
        await _expunge(path, uids);
        return _copyResult(copied);
      });

  @override
  Future<void> expunge(String path, List<int> uids) =>
      _guard(() => _expunge(path, uids));

  /// Flags exactly [uids] `\Deleted` and expunges exactly those. Without
  /// UIDPLUS a plain `EXPUNGE` would also remove anything else flagged
  /// `\Deleted`, so it only runs when nothing else is; otherwise the messages
  /// stay flagged (and hidden by the caller) until a server-side clean-up.
  Future<void> _expunge(String path, List<int> uids) async {
    if (uids.isEmpty) return;
    await _ensureSelected(path);
    final sequence = MessageSequence.fromIds(uids, isUid: true);
    await _c.uidStore(
      sequence,
      const [r'\Deleted'],
      action: StoreAction.add,
      silent: true,
    );
    if (_capabilities.uidPlus) {
      await _c.uidExpunge(sequence);
      return;
    }
    final flagged = await _c.uidSearchMessages(searchCriteria: 'DELETED');
    final others = (flagged.matchingSequence?.toList() ?? const <int>[]).where(
      (uid) => !uids.contains(uid),
    );
    if (others.isEmpty) await _c.expunge();
  }

  @override
  Future<RemoteAppendResult> append(
    String path,
    String source, {
    Set<String> flags = const {},
    DateTime? date,
  }) => _guard(() async {
    final result = await _c.appendMessageText(
      source,
      flags: flags.toList(),
      targetMailboxPath: path,
      internalDate: date,
    );
    final code = result.responseCodeAppendUid;
    return RemoteAppendResult(
      uidValidity: code?.uidValidity,
      uid: code?.targetSequence.toList().firstOrNull,
    );
  });

  // --- Folder management -----------------------------------------------------------------

  /// `enough_mail_plus` checks a created folder by listing it with the
  /// folder's own name as the LIST *reference*, which finds nothing even when
  /// the CREATE worked, and then reports an error. That error is therefore
  /// verified against a fresh folder list instead of being believed.
  @override
  Future<void> createFolder(String path) => _guard(() async {
    try {
      await _c.createMailbox(path);
    } on ImapException catch (error) {
      if (!(error.message ?? '').startsWith('Unable to find just created')) {
        rethrow;
      }
    }
    await _refreshMailboxes();
    if (!_mailboxes.containsKey(path)) {
      throw DirectMailException(DirectErrorKind.imapCommandFailed);
    }
  });

  @override
  Future<void> renameFolder(String from, String to) => _guard(() async {
    await _leave(from);
    await _c.renameMailbox(await _mailbox(from), to);
    _mailboxes.clear();
  });

  @override
  Future<void> deleteFolder(String path) => _guard(() async {
    await _leave(path);
    await _c.deleteMailbox(await _mailbox(path));
    _mailboxes.remove(path);
  });

  // --- Search and quota -------------------------------------------------------------------

  @override
  Future<List<int>> search(String path, RemoteSearchQuery query) =>
      _guard(() async {
        await _ensureSelected(path);
        final criteria = _criteria(query);
        final result = await _c.uidSearchMessages(searchCriteria: criteria);
        return (result.matchingSequence?.toList() ?? const <int>[])..sort();
      });

  static String _criteria(RemoteSearchQuery q) {
    final parts = <String>[];
    void term(String key, String? value) {
      if (value == null || value.trim().isEmpty) return;
      parts.add('$key ${_quote(value.trim())}');
    }

    term('TEXT', q.text);
    term('FROM', q.from);
    term('TO', q.to);
    term('SUBJECT', q.subject);
    if (q.since != null) parts.add('SINCE ${_imapDate(q.since!)}');
    if (q.before != null) parts.add('BEFORE ${_imapDate(q.before!)}');
    if (q.unseen == true) parts.add('UNSEEN');
    if (q.unseen == false) parts.add('SEEN');
    if (q.flagged == true) parts.add('FLAGGED');
    if (q.flagged == false) parts.add('UNFLAGGED');
    return parts.isEmpty ? 'ALL' : parts.join(' ');
  }

  static String _quote(String value) {
    if (value.runes.any((r) => r > 0x7e || r < 0x20)) {
      // Non-ASCII search needs a literal and CHARSET UTF-8; the library sends
      // quoted strings as they are. Rather than send something a server may
      // read as the wrong bytes, such searches stay on the local store.
      throw DirectMailException(DirectErrorKind.capabilityMissing);
    }
    return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  static String _imapDate(DateTime date) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    final d = date.toUtc();
    return '${d.day}-${months[d.month - 1]}-${d.year}';
  }

  @override
  Future<RemoteQuota?> quota() => _guard(() async {
    if (!_capabilities.quota) return null;
    final roots = await _c.getQuotaRoot(mailboxName: 'INBOX');
    for (final result in roots.quotaRoots.values) {
      for (final limit in result.resourceLimits) {
        if (limit.name.toUpperCase() == 'STORAGE' &&
            limit.usageLimit != null &&
            limit.usageLimit! > 0) {
          return RemoteQuota(
            usedBytes: (limit.currentUsage ?? 0) * 1024,
            limitBytes: limit.usageLimit! * 1024,
          );
        }
      }
    }
    return null;
  });

  // --- Push ----------------------------------------------------------------------------------

  /// IDLE renews every 9 minutes (servers drop it after 30, NAT tables
  /// sooner) by a quick `DONE` and a new `IDLE`.
  static const idleRenewal = Duration(minutes: 9);

  @override
  Stream<ImapPush> idle(String path) {
    late final StreamController<ImapPush> controller;
    StreamSubscription<ImapEvent>? events;
    Timer? renewal;
    var running = false;

    Future<void> start() async {
      final client = _c;
      await _ensureSelected(path);
      events ??= client.eventStream.listen((event) {
        if (controller.isClosed) return;
        if (event is ImapMessagesExistEvent) {
          controller.add(ImapPush.newMail);
        } else if (event is ImapExpungeEvent || event is ImapVanishedEvent) {
          controller.add(ImapPush.expunged);
        } else if (event is ImapFetchEvent) {
          controller.add(ImapPush.flagsChanged);
        }
      });
      await client.idleStart();
      running = true;
      renewal?.cancel();
      renewal = Timer.periodic(idleRenewal, (_) async {
        try {
          await client.idleDone();
          await client.idleStart();
        } catch (error) {
          if (!controller.isClosed) {
            controller.addError(DirectMailException.from(error));
          }
        }
      });
    }

    Future<void> stop() async {
      renewal?.cancel();
      await events?.cancel();
      events = null;
      if (running) {
        running = false;
        try {
          await _client?.idleDone();
        } catch (_) {}
      }
    }

    controller = StreamController<ImapPush>(
      onListen: () async {
        try {
          if (!_capabilities.idle) {
            throw DirectMailException(DirectErrorKind.capabilityMissing);
          }
          await start();
        } catch (error) {
          if (!controller.isClosed) {
            controller.addError(DirectMailException.from(error));
          }
        }
      },
      onCancel: stop,
    );
    return controller.stream;
  }
}
