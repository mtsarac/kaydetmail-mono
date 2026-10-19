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

  Future<ApiMailFolder> createFolder(String name, {String? parentId}) async =>
      throw _unsupported();
  Future<ApiMailFolder> renameFolder(String id, String name) async =>
      throw _unsupported();
  Future<ApiMailFolder> setFolderParent(String id, String? parentId) async =>
      throw _unsupported();
  Future<ApiMailFolder> setFolderRole(String id, String? role) async =>
      throw _unsupported();
  Future<void> deleteFolder(String id) async => throw _unsupported();

  Future<BulkActionResult> mailAction(String id, String action) async =>
      throw _unsupported();
  Future<BulkActionResult> moveMail(String id, String folderId) async =>
      throw _unsupported();
  Future<BulkActionResult> copyMail(String id, String folderId) async =>
      throw _unsupported();
  Future<List<BulkActionResult>> bulkAction(
    String action,
    List<String> mailIds, {
    String? folderId,
  }) async => throw _unsupported();

  Future<List<BulkActionResult>> setPinned(
    List<String> mailIds,
    bool pinned,
  ) async => throw _unsupported();
  Future<List<String>> getPinnedMailIds() async => throw _unsupported();
  Future<void> setSnooze(String mailId, DateTime untilUtc) async =>
      throw _unsupported();
  Future<void> clearSnooze(String mailId) async => throw _unsupported();
  Future<Map<String, DateTime>> getSnoozed() async => throw _unsupported();
  Future<List<TrustedSender>> getTrustedSenders() async => throw _unsupported();
  Future<TrustedSender> addTrustedSender(
    TrustedSenderKind kind,
    String value,
  ) async => throw _unsupported();
  Future<void> removeTrustedSender(String id) async => throw _unsupported();

  Future<List<Map<String, dynamic>>> getLabels() async => throw _unsupported();
  Future<Map<String, dynamic>> createLabel(String name, int color) async =>
      throw _unsupported();
  Future<Map<String, dynamic>> updateLabel(
    String id,
    String name,
    int color,
  ) async => throw _unsupported();
  Future<void> deleteLabel(String id) async => throw _unsupported();
  Future<Map<String, List<String>>> getLabelAssignments() async =>
      throw _unsupported();
  Future<void> assignLabels(
    List<String> mailIds,
    List<String> labelIds,
  ) async => throw _unsupported();
  Future<void> unassignLabels(
    List<String> mailIds,
    List<String> labelIds,
  ) async => throw _unsupported();
  Future<List<Map<String, dynamic>>> getContacts() async =>
      throw _unsupported();
  Future<Map<String, dynamic>> createContact(
    String email,
    String? displayName,
  ) async => throw _unsupported();
  Future<Map<String, dynamic>> updateContact(
    String id,
    String email,
    String? displayName,
  ) async => throw _unsupported();
  Future<void> deleteContact(String id) async => throw _unsupported();
  Future<List<MailTemplate>> getTemplates() async => throw _unsupported();
  Future<MailTemplate> createTemplate(MailTemplate template) async =>
      throw _unsupported();
  Future<MailTemplate> updateTemplate(MailTemplate template) async =>
      throw _unsupported();
  Future<void> deleteTemplate(String id) async => throw _unsupported();
  Future<({List<MailSignature> items, SignatureDefaults defaults})>
  getSignatures() async => throw _unsupported();
  Future<MailSignature> createSignature(MailSignature signature) async =>
      throw _unsupported();
  Future<MailSignature> updateSignatureItem(MailSignature signature) async =>
      throw _unsupported();
  Future<void> deleteSignature(String id) async => throw _unsupported();
  Future<SignatureDefaults> updateSignatureDefaults(
    SignatureDefaults defaults,
  ) async => throw _unsupported();
  Future<List<MailIdentity>> getIdentities() async => throw _unsupported();
  Future<MailIdentity> createIdentity(MailIdentity identity) async =>
      throw _unsupported();
  Future<MailIdentity> updateIdentity(MailIdentity identity) async =>
      throw _unsupported();
  Future<void> deleteIdentity(String id) async => throw _unsupported();

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

  Future<Email> getDraft(
    String id, {
    required MailFolder Function(String folderId) resolveFolder,
  }) async => throw _unsupported();
  Future<DraftResult> createDraft({
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    String subject = '',
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
  }) async => throw _unsupported();
  Future<DraftResult> updateDraft(
    String id, {
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    String subject = '',
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
  }) async => throw _unsupported();
  Future<void> deleteDraft(String id) async => throw _unsupported();
  Future<SendDraftResult> sendDraft(
    String id, {
    required String idempotencyKey,
  }) async => throw _unsupported();
  Future<ComposePrefill> getComposePrefill(
    String sourceMailId,
    String kind,
  ) async => throw _unsupported();
  Future<ComposeLimits> getComposeLimits() async => throw _unsupported();
  Future<SendResult> sendMail({
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
    required String idempotencyKey,
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
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
