/// One mail address with an optional display name.
class MailRecipient {
  const MailRecipient(this.address, [this.displayName = '']);

  final String address;
  final String displayName;

  @override
  bool operator ==(Object other) =>
      other is MailRecipient &&
      other.address.toLowerCase() == address.toLowerCase();

  @override
  int get hashCode => address.toLowerCase().hashCode;

  @override
  String toString() =>
      displayName.isEmpty ? address : '$displayName <$address>';
}

class ResolvedRecipients {
  const ResolvedRecipients({
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
  });

  final List<MailRecipient> to;
  final List<MailRecipient> cc;
  final List<MailRecipient> bcc;
}

/// Who a reply goes to. Ported from the backend's `MailRecipientResolver`,
/// with one deliberate improvement: reply-all drops *every* address the user
/// sends as (their identities), not only the account address.
class MailRecipients {
  const MailRecipients._();

  /// Reply: the sender, or `Reply-To` when the message names one.
  static ResolvedRecipients reply({
    required List<MailRecipient> from,
    List<MailRecipient> replyTo = const [],
  }) => _resolve(to: replyTo.isNotEmpty ? replyTo : from);

  /// Reply-all: (Reply-To or From) + To as the new To, Cc stays Cc. The
  /// user's own addresses are removed and nobody appears twice (case
  /// insensitive); Bcc of the source is never exposed.
  static ResolvedRecipients replyAll({
    required List<MailRecipient> from,
    required List<MailRecipient> to,
    List<MailRecipient> replyTo = const [],
    List<MailRecipient> cc = const [],
    required Iterable<String> ownAddresses,
  }) => _resolve(
    to: [...(replyTo.isNotEmpty ? replyTo : from), ...to],
    cc: cc,
    own: ownAddresses,
  );

  static ResolvedRecipients _resolve({
    List<MailRecipient> to = const [],
    List<MailRecipient> cc = const [],
    Iterable<String> own = const [],
  }) {
    final skip = {for (final a in own) a.trim().toLowerCase()};
    final seen = <String>{};
    List<MailRecipient> keep(List<MailRecipient> source) => [
      for (final r in source)
        if (isUsableAddress(r.address) &&
            !skip.contains(r.address.trim().toLowerCase()) &&
            seen.add(r.address.trim().toLowerCase()))
          MailRecipient(r.address.trim(), r.displayName),
    ];
    return ResolvedRecipients(to: keep(to), cc: keep(cc));
  }

  /// Has exactly one `@` with something on both sides and no whitespace.
  static bool isUsableAddress(String value) =>
      RegExp(r'^[^@\s<>,;]+@[^@\s<>,;]+$').hasMatch(value.trim());
}
