/// Pure threading helpers, ported from the backend's `ConversationEngine` so
/// a message gets the same thread on this device as it does on the server.
class MailThreading {
  const MailThreading._();

  static final RegExp _replyPrefix = RegExp(
    r'^(?:(?:RE|FWD|FW|SV|TR|ENC|ANTW|VV|VO|YNT|İLT|ILT|AW|WG)\s*:\s*)+',
    caseSensitive: false,
  );

  /// Removes Re:/Fwd:/FW:/SV:/TR: style prefixes (repeated, any case,
  /// including Turkish ones) and collapses whitespace.
  static String normalizeSubject(String? subject) => (subject ?? '')
      .trim()
      .replaceFirst(_replyPrefix, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Trims and strips surrounding angle brackets. Idempotent.
  static String normalizeMessageId(String? messageId) {
    var value = (messageId ?? '').trim();
    while (value.length >= 2 && value.startsWith('<') && value.endsWith('>')) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value;
  }

  /// Message ids of a `References` header, normalised, in order, de-duplicated.
  static List<String> parseReferences(String? references) {
    final seen = <String>{};
    return [
      for (final part in (references ?? '').split(RegExp(r'[\s,]+')))
        if (normalizeMessageId(part) case final id when id.isNotEmpty)
          if (seen.add(id)) id,
    ];
  }

  /// Threading headers for a reply to a message (RFC 5322 §3.6.4):
  /// In-Reply-To is the source Message-ID; References is the source's chain
  /// followed by the source Message-ID.
  static ({String inReplyTo, String references}) replyHeaders(
    String? sourceMessageId,
    String? sourceReferences,
  ) {
    final messageId = normalizeMessageId(sourceMessageId);
    final seen = <String>{};
    final chain = [
      for (final id in [...parseReferences(sourceReferences), messageId])
        if (id.isNotEmpty && seen.add(id.toLowerCase())) id,
    ];
    return (inReplyTo: messageId, references: chain.join(' '));
  }
}
