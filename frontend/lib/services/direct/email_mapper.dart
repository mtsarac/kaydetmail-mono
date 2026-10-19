import 'dart:convert';

import '../../models/email.dart';
import '../../models/mail_authentication.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_security.dart';
import 'direct_store.dart';
import 'html_sanitizer.dart';

/// Stored rows → the app's [Email].
///
/// Pins, labels, snoozes and the "answered/forwarded from KaydetMail" marks
/// are not set here: the repository stamps them on every mail, whatever
/// account it comes from.
class DirectEmailMapper {
  const DirectEmailMapper._();

  /// A list row: headers and a one-line preview in place of the body.
  static Email listItem(
    MessageRow row, {
    required MailFolder Function(String folderId) resolveFolder,
    required String accountId,
  }) => Email(
    id: row.localId,
    senderName: row.fromName.isNotEmpty ? row.fromName : row.fromAddress,
    senderEmail: row.fromAddress,
    recipients: [for (final r in row.to) r.address],
    subject: row.subject,
    bodyText: row.snippet,
    timestamp: DateTime.fromMillisecondsSinceEpoch(row.sortMs),
    isRead: row.isRead,
    isStarred: row.isFlagged,
    imapAnswered: row.isAnswered,
    forwardedFromKaydetMail: row.isForwarded,
    hasAttachments: row.hasAttachments,
    accountId: accountId,
    folder: resolveFolder(row.folderId),
    threadId: row.threadId,
  );

  /// The open mail: full headers, body, attachments and checks.
  static Email detail(
    MessageRow row,
    BodyRow body,
    List<PartRow> parts, {
    required MailFolder Function(String folderId) resolveFolder,
    required String accountId,
    bool allowRemoteImages = false,
  }) {
    final html = body.html == null
        ? null
        : allowRemoteImages
        ? MailHtmlSanitizer.unblockRemoteImages(body.html!)
        : body.html;
    return listItem(
      row,
      resolveFolder: resolveFolder,
      accountId: accountId,
    ).copyWith(
      cc: [for (final r in row.cc) r.address],
      bcc: [for (final r in row.bcc) r.address],
      bodyText: body.text,
      bodyHtml: html,
      hasRemoteContent: body.hasRemoteContent,
      remoteImageHosts: body.remoteImageHosts,
      trackingPixelHosts: body.trackingHosts,
      remoteImagesAllowed: allowRemoteImages,
      attachments: [
        for (final part in parts)
          Attachment(
            id: part.partId,
            name: part.filename,
            sizeBytes: part.size,
            mimeType: part.mime,
          ),
      ],
      hasAttachments: parts.isNotEmpty,
      headers: {
        if (row.messageId.isNotEmpty) 'message-id': row.messageId,
        if (body.listUnsubscribe != null)
          'list-unsubscribe': body.listUnsubscribe!,
        if (body.listUnsubscribePost != null)
          'list-unsubscribe-post': body.listUnsubscribePost!,
        if (body.receiptTo != null)
          'disposition-notification-to': body.receiptTo!,
        if (row.replyTo.isNotEmpty) 'reply-to': row.replyTo.first.address,
      },
      authentication: _authentication(body.authJson),
      security: _security(body.securityJson),
    );
  }

  static MailAuthentication? _authentication(String? json) {
    if (json == null) return null;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      final auth = MailAuthentication(
        authservId: m['authservId'] as String?,
        spf: m['spf'] as String?,
        dkim: m['dkim'] as String?,
        dmarc: m['dmarc'] as String?,
      );
      return auth.hasResults ? auth : null;
    } catch (_) {
      return null;
    }
  }

  static MailContentSecurity? _security(String? json) {
    if (json == null) return null;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      return MailContentSecurity(
        signed: m['signed'] as String?,
        encrypted: m['encrypted'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  // --- Conversation messages ------------------------------------------------------

  /// One message in the wire shape of a conversation response with bodies
  /// (`include=body`), which is what the repository's thread view reads.
  static Map<String, dynamic> conversationMessage(
    MessageRow row,
    BodyRow? body,
  ) => {
    'id': row.localId,
    'conversationId': row.threadId,
    'fromAddress': row.fromAddress,
    'fromDisplayName': row.fromName,
    'to': [for (final r in row.to) r.address],
    'cc': [for (final r in row.cc) r.address],
    'bcc': [for (final r in row.bcc) r.address],
    'subject': row.subject,
    'bodyText': body?.text ?? row.snippet,
    'folderId': row.folderId,
    'isRead': row.isRead,
    'hasAttachments': row.hasAttachments,
    'receivedAt': DateTime.fromMillisecondsSinceEpoch(
      row.sortMs,
      isUtc: true,
    ).toIso8601String(),
    'body': {
      'html': body?.html,
      'hasRemoteContent': body?.hasRemoteContent ?? false,
      'remoteImageHosts': body?.remoteImageHosts ?? const <String>[],
      'trackingPixelHosts': body?.trackingHosts ?? const <String>[],
      'remoteImagesAllowed': false,
    },
  };

  /// The reverse of [conversationMessage].
  static Email fromConversationMessage(
    Map<String, dynamic> item, {
    required MailFolder Function(String folderId) resolveFolder,
    required String accountId,
  }) {
    List<String> list(Object? v) => v is List
        ? [
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          ]
        : const [];
    final body = item['body'] is Map<String, dynamic>
        ? item['body'] as Map<String, dynamic>
        : null;
    final address = item['fromAddress'] as String? ?? '';
    final name = item['fromDisplayName'] as String? ?? '';
    return Email(
      id: item['id'] as String,
      senderName: name.isNotEmpty ? name : address,
      senderEmail: address,
      recipients: list(item['to']),
      cc: list(item['cc']),
      bcc: list(item['bcc']),
      subject: item['subject'] as String? ?? '',
      bodyText: item['bodyText'] as String? ?? '',
      bodyHtml: (body?['html'] as String?)?.isNotEmpty == true
          ? body!['html'] as String
          : null,
      hasRemoteContent: body?['hasRemoteContent'] as bool? ?? false,
      remoteImageHosts: list(body?['remoteImageHosts']),
      trackingPixelHosts: list(body?['trackingPixelHosts']),
      remoteImagesAllowed: body?['remoteImagesAllowed'] as bool? ?? false,
      timestamp:
          DateTime.tryParse(item['receivedAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
      isRead: item['isRead'] as bool? ?? false,
      hasAttachments: item['hasAttachments'] as bool? ?? false,
      accountId: accountId,
      folder: resolveFolder(item['folderId'] as String),
      threadId: item['conversationId'] as String? ?? '',
    );
  }
}
