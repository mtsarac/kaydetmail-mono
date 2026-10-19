import 'dart:typed_data';

import '../../models/account_notification_settings.dart';
import '../../models/compose_limits.dart';
import '../../models/compose_prefill.dart';
import '../../models/email.dart';
import '../../models/folder_sync_status.dart';
import '../../models/mail_account.dart';
import '../../models/mail_security.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_header_entry.dart';
import '../../models/mail_session.dart';
import '../../models/mail_signature.dart';
import '../../models/mail_template.dart';
import '../../models/remote_search_result.dart';
import '../../models/scheduled_send.dart';
import '../../models/scheduled_send_detail.dart';
import '../../models/trusted_sender.dart';
import '../api_auth_service.dart' show ManualMailServer;
import 'gateway_models.dart';

/// Everything a connected mailbox needs from "the other side" of the app.
///
/// One account talks to exactly one gateway for its whole life:
/// `ApiMailService` (KaydetMail backend over HTTP) or `DirectMailGateway`
/// (IMAP/SMTP from this device, with a persistent local store). The
/// repository modules (`lib/repositories/api/`) only see this contract, so
/// optimistic updates, unified-inbox fan-out and account routing are shared.
///
/// Ids are opaque strings owned by the gateway: backend GUIDs for one, local
/// stable ids for the other. A gateway that cannot offer an operation throws
/// an `ApiException` with the `unsupported_operation` code; callers check
/// `AccountCapabilities` first so users never see such a failure.
abstract interface class MailGateway {
  // --- Account ---------------------------------------------------------

  Future<MailAccount> getAccount();
  Future<AccountQuota?> getQuota();
  Future<void> updateSignature(String? signature);
  Future<MailAccount> reconnect({
    required String password,
    ManualMailServer? imap,
    ManualMailServer? smtp,
  });
  Future<void> deleteAccount();
  Future<List<MailSession>> getSessions();
  Future<void> deleteSession(String sessionId);
  Future<List<FolderSyncStatus>> getSyncStatus();
  Future<({String scope, Set<String> syncedFolderIds})> getSyncScope();
  Future<({String scope, Set<String> syncedFolderIds})> updateSyncScope(
    String scope, {
    List<String>? folderIds,
  });
  Future<AccountNotificationSettings> getNotificationSettings();
  Future<AccountNotificationSettings> updateNotificationSettings(
    AccountNotificationSettings settings,
  );
  Future<DeviceRegistration> registerDevice({
    required String token,
    required String platform,
    required String appVersion,
    required String locale,
  });
  Future<void> unregisterDevice(String id);

  // --- Folders ---------------------------------------------------------

  Future<List<ApiMailFolder>> getFolders();
  Future<ApiMailFolder> createFolder(String name, {String? parentId});
  Future<ApiMailFolder> renameFolder(String id, String name);
  Future<ApiMailFolder> setFolderParent(String id, String? parentId);
  Future<ApiMailFolder> setFolderRole(String id, String? role);
  Future<void> deleteFolder(String id);
  Future<int> refreshFolders();

  /// Brings the local view of [folderId] up to date with the mail server and
  /// completes when that is done.
  Future<void> syncFolderId(String folderId);

  // --- Mail ------------------------------------------------------------

  Future<MailListPage> getMails({
    required String folderId,
    required MailFolder Function(String folderId) resolveFolder,
    int page = 1,
    int pageSize = 20,
    bool? isRead,
    bool? hasAttachments,
    String? search,
  });
  Future<Email> getMail(
    String id, {
    required MailFolder Function(String folderId) resolveFolder,
    bool allowRemoteImages = false,
  });
  Future<List<MailHeaderEntry>> getMailHeaders(String id);
  Future<String> getMailSource(String id);
  Future<MailSignatureVerification> getMailSignature(String id);
  Future<Uint8List> downloadAttachment(String mailId, String attachmentId);
  Future<ConversationListPage> getConversations({
    int page = 1,
    int pageSize = 50,
  });
  Future<ApiConversation> getConversation(String id);
  Future<ApiConversation> getConversationWithBodies(String id);

  /// Maps one wire-shaped `include=body` conversation message (as found in
  /// [ApiConversation.messages]) to an [Email].
  Email mapConversationMessage(
    Map<String, dynamic> item,
    MailFolder Function(String folderId) resolveFolder,
  );
  Future<BulkActionResult> mailAction(String id, String action);
  Future<BulkActionResult> moveMail(String id, String folderId);
  Future<BulkActionResult> copyMail(String id, String folderId);
  Future<List<BulkActionResult>> bulkAction(
    String action,
    List<String> mailIds, {
    String? folderId,
  });

  // --- KaydetMail metadata (pins, snoozes, trusted senders) ---------------

  Future<List<BulkActionResult>> setPinned(List<String> mailIds, bool pinned);
  Future<List<String>> getPinnedMailIds();
  Future<void> setSnooze(String mailId, DateTime untilUtc);
  Future<void> clearSnooze(String mailId);
  Future<Map<String, DateTime>> getSnoozed();
  Future<List<TrustedSender>> getTrustedSenders();
  Future<TrustedSender> addTrustedSender(TrustedSenderKind kind, String value);
  Future<void> removeTrustedSender(String id);

  // --- Labels, contacts, templates, signatures, identities ------------------

  Future<List<Map<String, dynamic>>> getLabels();
  Future<Map<String, dynamic>> createLabel(String name, int color);
  Future<Map<String, dynamic>> updateLabel(String id, String name, int color);
  Future<void> deleteLabel(String id);
  Future<Map<String, List<String>>> getLabelAssignments();
  Future<void> assignLabels(List<String> mailIds, List<String> labelIds);
  Future<void> unassignLabels(List<String> mailIds, List<String> labelIds);
  Future<List<Map<String, dynamic>>> getContacts();
  Future<Map<String, dynamic>> createContact(String email, String? displayName);
  Future<Map<String, dynamic>> updateContact(
    String id,
    String email,
    String? displayName,
  );
  Future<void> deleteContact(String id);
  Future<List<MailTemplate>> getTemplates();
  Future<MailTemplate> createTemplate(MailTemplate template);
  Future<MailTemplate> updateTemplate(MailTemplate template);
  Future<void> deleteTemplate(String id);
  Future<({List<MailSignature> items, SignatureDefaults defaults})>
  getSignatures();
  Future<MailSignature> createSignature(MailSignature signature);
  Future<MailSignature> updateSignatureItem(MailSignature signature);
  Future<void> deleteSignature(String id);
  Future<SignatureDefaults> updateSignatureDefaults(SignatureDefaults defaults);
  Future<List<MailIdentity>> getIdentities();
  Future<MailIdentity> createIdentity(MailIdentity identity);
  Future<MailIdentity> updateIdentity(MailIdentity identity);
  Future<void> deleteIdentity(String id);

  // --- Search ------------------------------------------------------------

  /// Local-store (cached) search; all filters are optional and AND-ed.
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
  });

  /// Asks the mail server itself and imports what it finds.
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
  });

  // --- Compose / send ------------------------------------------------------

  Future<Email> getDraft(
    String id, {
    required MailFolder Function(String folderId) resolveFolder,
  });
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
  });
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
  });
  Future<void> deleteDraft(String id);
  Future<SendDraftResult> sendDraft(
    String id, {
    required String idempotencyKey,
  });
  Future<ComposePrefill> getComposePrefill(String sourceMailId, String kind);
  Future<ComposeLimits> getComposeLimits();
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
  });

  // --- Scheduled send ------------------------------------------------------

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
  });
  Future<void> cancelScheduledSend(String id);
  Future<ScheduledSendDetail> getScheduledSend(String id);
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
  });
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
  });
  Future<List<ScheduledSend>> listScheduledSends();
}
