part of '../direct_mail_gateway.dart';

DirectMailException _unsupported() =>
    DirectMailException(DirectErrorKind.unsupportedOperation);

/// Everything a direct account cannot (yet) do. Each group that gets a real
/// implementation is mixed in after this one and overrides its stubs, so the
/// list shrinks as the engine grows; callers check `AccountCapabilities`
/// first, so users never see these.
mixin _DirectUnsupportedApi on _DirectGatewayBase {
  Future<List<MailSession>> getSessions() async => throw _unsupported();
  Future<void> deleteSession(String sessionId) async => throw _unsupported();

  Future<MailListPage> search({
    required String query,
    required MailFolder Function(String folderId) resolveFolder,
    String? folderId,
    String? conversationId,
    String? from,
    String? to,
    DateTime? fromDate,
    DateTime? toDate,
    bool? isRead,
    bool? flagged,
    bool? hasAttachment,
    String? labelId,
    int page = 1,
    int pageSize = 20,
  }) async => throw _unsupported();
  Future<RemoteSearchResult> searchRemote({
    required String query,
    String? folderId,
    String? conversationId,
    String? from,
    String? to,
    DateTime? fromDate,
    DateTime? toDate,
    bool? isRead,
    bool? flagged,
    bool? hasAttachment,
    String? labelId,
  }) async => throw _unsupported();

  Future<ScheduledSend> scheduleSend({
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
    bool requestReadReceipt = false,
    required DateTime sendAtUtc,
    required String idempotencyKey,
  }) async => throw _unsupported();
  Future<void> cancelScheduledSend(String id) async => throw _unsupported();
  Future<ScheduledSendDetail> getScheduledSend(String id) async =>
      throw _unsupported();
  Future<void> updateScheduledSend({
    required String id,
    required int expectedRevision,
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    required DateTime sendAtUtc,
    List<String> keepAttachmentIds = const [],
    List<Attachment> attachments = const [],
  }) async => throw _unsupported();
  Future<void> rescheduleFailedSend({
    required String id,
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    List<String>? attachmentIds,
    required DateTime sendAtUtc,
    required String idempotencyKey,
  }) async => throw _unsupported();
  Future<List<ScheduledSend>> listScheduledSends() async =>
      throw _unsupported();
}
