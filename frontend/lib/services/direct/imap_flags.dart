/// IMAP flags and keywords, and how the app holds them.
class ImapFlags {
  const ImapFlags({
    this.isRead = false,
    this.isFlagged = false,
    this.isAnswered = false,
    this.isDraft = false,
    this.isDeleted = false,
    this.isForwarded = false,
    this.keywords = const [],
  });

  static const seen = r'\Seen';
  static const flagged = r'\Flagged';
  static const answered = r'\Answered';
  static const draft = r'\Draft';
  static const deleted = r'\Deleted';
  static const forwarded = r'$Forwarded';

  final bool isRead;
  final bool isFlagged;
  final bool isAnswered;
  final bool isDraft;
  final bool isDeleted;
  final bool isForwarded;

  /// Other keywords, kept as the server wrote them (sorted, so two reads of
  /// the same flags compare equal).
  final List<String> keywords;

  /// Reads the flags of a `FETCH` response. System flags match in any case;
  /// `\Recent` is session state and is dropped.
  factory ImapFlags.fromWire(Iterable<String> wire) {
    var seenFlag = false,
        flaggedFlag = false,
        answeredFlag = false,
        draftFlag = false,
        deletedFlag = false,
        forwardedFlag = false;
    final keywords = <String>{};
    for (final raw in wire) {
      final flag = raw.trim();
      switch (flag.toLowerCase()) {
        case r'\seen':
          seenFlag = true;
        case r'\flagged':
          flaggedFlag = true;
        case r'\answered':
          answeredFlag = true;
        case r'\draft':
          draftFlag = true;
        case r'\deleted':
          deletedFlag = true;
        case r'$forwarded' || r'forwarded':
          forwardedFlag = true;
        case r'\recent' || '':
          break;
        default:
          keywords.add(flag);
      }
    }
    return ImapFlags(
      isRead: seenFlag,
      isFlagged: flaggedFlag,
      isAnswered: answeredFlag,
      isDraft: draftFlag,
      isDeleted: deletedFlag,
      isForwarded: forwardedFlag,
      keywords: keywords.toList()..sort(),
    );
  }

  /// Whether [other] says the same as this.
  bool sameAs({
    required bool isRead,
    required bool isFlagged,
    required bool isAnswered,
    required bool isDraft,
    required bool isDeleted,
    required bool isForwarded,
    required List<String> keywords,
  }) =>
      this.isRead == isRead &&
      this.isFlagged == isFlagged &&
      this.isAnswered == isAnswered &&
      this.isDraft == isDraft &&
      this.isDeleted == isDeleted &&
      this.isForwarded == isForwarded &&
      _sameList((List.of(keywords)..sort()), this.keywords);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
