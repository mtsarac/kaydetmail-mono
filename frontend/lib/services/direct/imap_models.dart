import 'package:enough_mail_plus/enough_mail.dart' show MimeMessage;
import 'package:flutter/foundation.dart';

/// What a folder is for. The wire names (`Inbox`, `Sent`, `Drafts`, `Trash`,
/// `Junk`, `Archive`, `Custom`) are the ones the backend uses for
/// `ApiMailFolder.type`, so the repository's folder mapping works unchanged.
enum FolderRole {
  inbox('Inbox'),
  sent('Sent'),
  drafts('Drafts'),
  trash('Trash'),
  junk('Junk'),
  archive('Archive'),
  custom('Custom');

  const FolderRole(this.wireName);
  final String wireName;

  static FolderRole fromWireName(String? value) => FolderRole.values.firstWhere(
    (role) => role.wireName.toLowerCase() == value?.toLowerCase(),
    orElse: () => FolderRole.custom,
  );

  /// Roles a user may assign to a folder (Inbox and Archive are detected).
  bool get isAssignable => switch (this) {
    FolderRole.sent ||
    FolderRole.drafts ||
    FolderRole.trash ||
    FolderRole.junk => true,
    _ => false,
  };

  /// Whether this role is for system use and the folder may not be renamed,
  /// moved or deleted.
  bool get isProtected => this != FolderRole.custom;
}

/// One folder as the server lists it.
@immutable
class RemoteFolder {
  const RemoteFolder({
    required this.path,
    required this.name,
    required this.delimiter,
    this.attributes = const {},
    this.specialUse,
  });

  /// Full IMAP name, e.g. `INBOX.Sent` or `Projeler/Arşiv`.
  final String path;

  /// Last component of [path].
  final String name;

  /// Hierarchy delimiter; empty when the server has a flat namespace.
  final String delimiter;

  /// Lower-case LIST attributes (`\noselect`, `\haschildren`, `\sent`, …).
  final Set<String> attributes;

  /// Role announced by the server through SPECIAL-USE, when it does.
  final FolderRole? specialUse;

  bool get selectable =>
      !attributes.contains(r'\noselect') &&
      !attributes.contains(r'\nonexistent');

  /// The path of the parent folder, or null at the top level.
  String? get parentPath {
    if (delimiter.isEmpty) return null;
    final index = path.lastIndexOf(delimiter);
    return index <= 0 ? null : path.substring(0, index);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteFolder &&
      other.path == path &&
      other.delimiter == delimiter &&
      setEquals(other.attributes, attributes) &&
      other.specialUse == specialUse;

  @override
  int get hashCode => Object.hash(path, delimiter, specialUse);
}

/// What `SELECT` told us about a folder.
@immutable
class RemoteFolderState {
  const RemoteFolderState({
    required this.uidValidity,
    required this.uidNext,
    required this.exists,
    this.highestModSeq,
    this.unseen,
  });

  final int uidValidity;
  final int uidNext;
  final int exists;

  /// Only when the server supports CONDSTORE/QRESYNC.
  final int? highestModSeq;

  /// Only when the server reported it (`STATUS` / `SELECT`).
  final int? unseen;
}

/// A message as a header-level fetch returns it.
@immutable
class RemoteMessage {
  const RemoteMessage({
    required this.uid,
    required this.flags,
    this.internalDate,
    this.size,
    this.mime,
  });

  final int uid;

  /// IMAP flags and keywords as written on the wire (`\Seen`, `\Flagged`,
  /// `\Answered`, `\Draft`, `\Deleted`, `$Forwarded`, …).
  final Set<String> flags;
  final DateTime? internalDate;
  final int? size;

  /// Parsed headers (and, for a full fetch, the whole body).
  final MimeMessage? mime;
}

/// UID and flags only; the cheap probe that finds flag changes.
@immutable
class RemoteFlags {
  const RemoteFlags(this.uid, this.flags);
  final int uid;
  final Set<String> flags;
}

/// What a server announces. Built from its raw `CAPABILITY` list so a missing
/// getter in the client library never hides a real capability.
@immutable
class ImapCapabilities {
  const ImapCapabilities(this.names);

  factory ImapCapabilities.fromNames(Iterable<String> names) =>
      ImapCapabilities({for (final n in names) n.toUpperCase()});

  final Set<String> names;

  bool has(String name) => names.contains(name.toUpperCase());

  bool get idle => has('IDLE');
  bool get uidPlus => has('UIDPLUS');
  bool get move => has('MOVE');
  bool get condStore => has('CONDSTORE') || has('QRESYNC');
  bool get qresync => has('QRESYNC');
  bool get namespace => has('NAMESPACE');
  bool get specialUse => has('SPECIAL-USE');
  bool get listStatus => has('LIST-STATUS');
  bool get quota => has('QUOTA');
  bool get utf8Accept => has('UTF8=ACCEPT');
  bool get id => has('ID');
  bool get unselect => has('UNSELECT');
  bool get sort => has('SORT');
  bool get literalPlus => has('LITERAL+') || has('LITERAL-');
}

/// Outcome of a COPY/MOVE/APPEND that tells where the message went.
@immutable
class RemoteCopyResult {
  const RemoteCopyResult({this.uidValidity, this.sourceUids, this.targetUids});

  /// UIDVALIDITY of the target folder, when the server sent `COPYUID`.
  final int? uidValidity;
  final List<int>? sourceUids;
  final List<int>? targetUids;

  /// The new UID of [sourceUid], or null when the server did not say.
  int? targetFor(int sourceUid) {
    final from = sourceUids;
    final to = targetUids;
    if (from == null || to == null || from.length != to.length) return null;
    final index = from.indexOf(sourceUid);
    return index < 0 ? null : to[index];
  }
}

@immutable
class RemoteAppendResult {
  const RemoteAppendResult({this.uidValidity, this.uid});
  final int? uidValidity;
  final int? uid;
}

@immutable
class RemoteQuota {
  const RemoteQuota({required this.usedBytes, required this.limitBytes});
  final int usedBytes;
  final int limitBytes;
}

/// Hierarchy information from `NAMESPACE`.
@immutable
class RemoteNamespace {
  const RemoteNamespace({this.personalPrefix = '', this.delimiter = '/'});

  /// `INBOX.` on many cPanel/Dovecot setups, empty on others.
  final String personalPrefix;
  final String delimiter;
}

/// A change the server pushed while idling.
enum ImapPush { newMail, expunged, flagsChanged }
