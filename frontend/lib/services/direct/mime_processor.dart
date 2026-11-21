import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail_plus/enough_mail.dart'
    show ContentDisposition, ContentInfo, MailAddress, MimeMessage;

import '../../models/mail_authentication.dart';
import '../../models/mail_security.dart';
import '../../utils/html_to_text.dart';
import 'direct_store.dart';
import 'html_sanitizer.dart';
import 'mail_recipients.dart';
import 'mail_threading.dart';

/// The list-level facts of a message, read from its headers alone.
class ParsedHeaders {
  const ParsedHeaders({
    required this.messageId,
    required this.inReplyTo,
    required this.references,
    required this.subject,
    required this.fromName,
    required this.fromAddress,
    required this.to,
    required this.cc,
    required this.bcc,
    required this.replyTo,
    required this.dateMs,
    required this.mayHaveAttachments,
  });

  final String messageId;
  final String inReplyTo;
  final String references;
  final String subject;
  final String fromName;
  final String fromAddress;
  final List<MailRecipient> to;
  final List<MailRecipient> cc;
  final List<MailRecipient> bcc;
  final List<MailRecipient> replyTo;

  /// The `Date` header in UTC epoch milliseconds, null when missing or
  /// unparseable.
  final int? dateMs;

  /// From the top-level `Content-Type`: `multipart/mixed` and non-text
  /// bodies usually carry attachments. Exact only once the body is read.
  final bool mayHaveAttachments;
}

/// A message body ready to store and show.
class ProcessedMail {
  const ProcessedMail({
    required this.text,
    required this.html,
    required this.parts,
    required this.snippet,
    required this.headers,
    this.authentication,
    this.security,
    this.authenticationJson,
    this.securityJson,
    this.receiptTo,
    this.listUnsubscribe,
    this.listUnsubscribePost,
  });

  /// Plain text; derived from the HTML when the sender sent only HTML.
  final String text;
  final SanitizedHtml html;

  /// Attachments to list (inline images shown in the body are not here).
  final List<PartDraft> parts;
  final String snippet;

  /// The few headers the app reads, lower-case keys.
  final Map<String, String> headers;
  final MailAuthentication? authentication;
  final MailContentSecurity? security;
  final String? authenticationJson;
  final String? securityJson;
  final String? receiptTo;
  final String? listUnsubscribe;
  final String? listUnsubscribePost;
}

/// Turns parsed MIME messages into the shapes the app stores and shows.
///
/// Parsing itself is `enough_mail_plus`'s (charsets such as windows-1254 and
/// iso-8859-9, RFC 2047/2231 encodings, quoted-printable, base64); this adds
/// what the backend's `IncomingMailMapper` and body renderer did.
class MimeProcessor {
  const MimeProcessor._();

  /// Largest inline image embedded in a body, and the most per message.
  static const maxInlineImageBytes = 512 * 1024;
  static const maxInlineTotalBytes = 2 * 1024 * 1024;

  static const _inlineImageTypes = {
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/gif',
    'image/webp',
    'image/bmp',
  };

  // --- Headers --------------------------------------------------------------

  static ParsedHeaders parseHeaders(MimeMessage m) {
    final from = m.from?.firstOrNull;
    final contentType = (m.getHeaderValue('content-type') ?? '').toLowerCase();
    return ParsedHeaders(
      messageId: MailThreading.normalizeMessageId(
        m.getHeaderValue('message-id'),
      ),
      inReplyTo: MailThreading.normalizeMessageId(
        m.getHeaderValue('in-reply-to'),
      ),
      references: MailThreading.parseReferences(m.getHeaderValue('references'))
          .join(' '),
      subject: _singleLine(m.decodeSubject() ?? ''),
      fromName: _singleLine(from?.personalName ?? ''),
      fromAddress: (from?.email ?? '').trim(),
      to: _recipients(m.to),
      cc: _recipients(m.cc),
      bcc: _recipients(m.bcc),
      replyTo: _recipients(m.replyTo),
      dateMs: _dateMs(m),
      mayHaveAttachments: _mayHaveAttachments(contentType),
    );
  }

  static List<MailRecipient> _recipients(List<MailAddress>? list) => [
    for (final a in list ?? const <MailAddress>[])
      if (a.email.trim().isNotEmpty)
        MailRecipient(a.email.trim(), _singleLine(a.personalName ?? '')),
  ];

  static String _singleLine(String value) =>
      value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

  static int? _dateMs(MimeMessage m) {
    try {
      return m.decodeDate()?.toUtc().millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static bool _mayHaveAttachments(String contentType) {
    if (contentType.isEmpty) return false;
    if (contentType.startsWith('multipart/mixed') ||
        contentType.startsWith('multipart/parallel')) {
      return true;
    }
    return const [
          'application/',
          'image/',
          'audio/',
          'video/',
        ].any(contentType.startsWith) &&
        !contentType.startsWith('application/pkcs7-mime');
  }

  // --- Body ----------------------------------------------------------------------

  static ProcessedMail processBody(
    MimeMessage m, {
    bool allowRemoteImages = false,
  }) {
    final rawHtml = _decodeHtml(m);
    final cidImages = <String, String>{};
    final embeddedCids = <String>{};
    var embeddedBytes = 0;

    if (rawHtml != null) {
      for (final cid in _referencedCids(rawHtml)) {
        final part = m.getPartWithContentId(cid);
        final mime = part?.mediaType.text.toLowerCase();
        final bytes = part?.decodeContentBinary();
        if (part == null ||
            bytes == null ||
            mime == null ||
            !_inlineImageTypes.contains(mime) ||
            bytes.length > maxInlineImageBytes ||
            embeddedBytes + bytes.length > maxInlineTotalBytes) {
          continue;
        }
        embeddedBytes += bytes.length;
        cidImages[cid] = 'data:$mime;base64,${base64.encode(bytes)}';
        embeddedCids.add(cid);
      }
    }

    final html = rawHtml == null
        ? SanitizedHtml.empty
        : MailHtmlSanitizer.sanitize(
            rawHtml,
            allowRemoteImages: allowRemoteImages,
            cidImages: cidImages,
          );

    var text = m.decodeTextPlainPart() ?? '';
    if (text.trim().isEmpty && html.html.trim().isNotEmpty) {
      text = htmlToPlainText(html.html);
    }
    text = text.replaceAll('\r\n', '\n').trim();

    final parts = _attachmentParts(m, embeddedCids);
    final headers = _selectedHeaders(m);
    final authentication = parseAuthentication(
      m.getHeaderValue('authentication-results'),
    );
    final security = detectSecurity(m, text);

    return ProcessedMail(
      text: text,
      html: html,
      parts: parts,
      snippet: snippetOf(text),
      headers: headers,
      authentication: authentication,
      security: security,
      authenticationJson: authentication == null
          ? null
          : jsonEncode({
              'authservId': authentication.authservId,
              'spf': authentication.spf,
              'dkim': authentication.dkim,
              'dmarc': authentication.dmarc,
            }),
      securityJson: security == null
          ? null
          : jsonEncode({
              'signed': security.signed,
              'encrypted': security.encrypted,
            }),
      receiptTo: _clean(m.getHeaderValue('disposition-notification-to')),
      listUnsubscribe: headers['list-unsubscribe'],
      listUnsubscribePost: headers['list-unsubscribe-post'],
    );
  }

  /// First 160 characters of the text, whitespace collapsed.
  static String snippetOf(String text) {
    final head = text.length > 600 ? text.substring(0, 600) : text;
    final compact = head.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= 160
        ? compact
        : compact.substring(0, 160).trimRight();
  }

  static String? _decodeHtml(MimeMessage m) {
    final html = m.decodeTextHtmlPart();
    return html == null || html.trim().isEmpty ? null : html;
  }

  static Set<String> _referencedCids(String html) => {
    for (final match in RegExp(
      r'''cid:\s*<?([^"'\s>)]+)>?''',
      caseSensitive: false,
    ).allMatches(html))
      match.group(1)!.toLowerCase(),
  };

  static List<PartDraft> _attachmentParts(
    MimeMessage m,
    Set<String> embeddedCids,
  ) {
    final seen = <String>{};
    final parts = <PartDraft>[];

    void add(ContentInfo info) {
      if (!seen.add(info.fetchId)) return;
      final cid = _stripBrackets(info.cid);
      if (cid != null && embeddedCids.contains(cid.toLowerCase())) return;
      final mime =
          (info.contentType?.mediaType.text ?? 'application/octet-stream')
              .toLowerCase();
      final part = m.getPart(info.fetchId);
      final size = part?.decodeContentBinary()?.length ?? info.size ?? 0;
      parts.add(
        PartDraft(
          partId: info.fetchId,
          filename: _fileName(info, mime),
          mime: mime,
          size: size,
          contentId: cid,
        ),
      );
    }

    for (final info in m.findContentInfo()) {
      add(info);
    }
    // Inline parts that are not text and that the body did not embed are
    // still the user's to open (a photo pasted into the mail, say).
    for (final info in m.findContentInfo(
      disposition: ContentDisposition.inline,
    )) {
      if (!info.isText) add(info);
    }
    return parts;
  }

  static String _fileName(ContentInfo info, String mime) {
    final name = (info.fileName ?? '').trim();
    if (name.isNotEmpty) return name.replaceAll(RegExp(r'[\\/\r\n]'), '_');
    if (mime == 'message/rfc822') return 'ileti.eml';
    final subtype = mime.contains('/') ? mime.split('/').last : 'bin';
    return 'ek.${subtype.replaceAll(RegExp(r'[^a-z0-9]'), '')}';
  }

  static String? _stripBrackets(String? cid) {
    if (cid == null) return null;
    final value = cid.trim().replaceAll(RegExp(r'^<|>$'), '');
    return value.isEmpty ? null : value;
  }

  static String? _clean(String? value) {
    final v = value?.replaceAll(RegExp(r'[\r\n]+\s*'), ' ').trim();
    return v == null || v.isEmpty ? null : v;
  }

  /// The headers the app reads from `Email.headers`.
  static Map<String, String> _selectedHeaders(MimeMessage m) {
    const names = [
      'message-id',
      'list-unsubscribe',
      'list-unsubscribe-post',
      'reply-to',
      'disposition-notification-to',
      'importance',
      'x-priority',
    ];
    return {for (final name in names) name: ?_clean(m.getHeaderValue(name))};
  }

  // --- Authentication-Results and S/MIME / PGP markers -----------------------------

  static const _authResults = {
    'pass', 'fail', 'softfail', 'neutral', 'none', 'temperror', 'permerror',
    'policy', //
  };

  /// Reads SPF, DKIM and DMARC out of an `Authentication-Results` header
  /// (RFC 8601). The device cannot verify anything itself: this is what the
  /// receiving server wrote down. `pass` wins when a method appears twice.
  static MailAuthentication? parseAuthentication(String? header) {
    final value = _clean(header);
    if (value == null) return null;
    final segments = value.split(';');
    final authservId = segments.first.trim().split(RegExp(r'\s+')).first;
    final found = <String, List<String>>{};
    for (final segment in segments.skip(1)) {
      final match = RegExp(r'^\s*([A-Za-z0-9_-]+)\s*=\s*([A-Za-z]+)')
          .firstMatch(segment);
      if (match == null) continue;
      final method = match.group(1)!.toLowerCase();
      var result = match.group(2)!.toLowerCase();
      if (result == 'hardfail') result = 'fail';
      if (_authResults.contains(result)) {
        found.putIfAbsent(method, () => []).add(result);
      }
    }
    String? result(String method) {
      final values = found[method];
      if (values == null || values.isEmpty) return null;
      return values.contains('pass') ? 'pass' : values.first;
    }

    final authentication = MailAuthentication(
      authservId: authservId.isEmpty ? null : authservId,
      spf: result('spf'),
      dkim: result('dkim'),
      dmarc: result('dmarc'),
    );
    return authentication.hasResults ? authentication : null;
  }

  /// Whether the message is signed or encrypted, from its structure. Nothing
  /// is verified or decrypted on the device.
  static MailContentSecurity? detectSecurity(MimeMessage m, String text) {
    String? signed;
    String? encrypted;
    final header = m.getHeaderValue('content-type');
    if (header != null && header.trim().isNotEmpty) {
      final lower = header.toLowerCase();
      final protocol = RegExp(r'''protocol\s*=\s*"?([^";\s]+)''')
          .firstMatch(lower)
          ?.group(1);
      if (lower.startsWith('multipart/signed')) {
        signed = switch (protocol) {
          'application/pkcs7-signature' ||
          'application/x-pkcs7-signature' => 'SMime',
          'application/pgp-signature' => 'OpenPgp',
          _ => null,
        };
      } else if (lower.startsWith('multipart/encrypted') &&
          protocol == 'application/pgp-encrypted') {
        encrypted = 'OpenPgp';
      } else if (lower.startsWith('application/pkcs7-mime') ||
          lower.startsWith('application/x-pkcs7-mime')) {
        if (RegExp(r'smime-type\s*=\s*"?signed-data').hasMatch(lower)) {
          signed = 'SMime';
        } else {
          encrypted = 'SMime';
        }
      }
    }
    if (signed == null && encrypted == null) {
      if (text.contains('-----BEGIN PGP SIGNED MESSAGE-----')) {
        signed = 'OpenPgp';
      } else if (text.contains('-----BEGIN PGP MESSAGE-----')) {
        encrypted = 'OpenPgp';
      }
    }
    return signed == null && encrypted == null
        ? null
        : MailContentSecurity(signed: signed, encrypted: encrypted);
  }

  /// Bytes of the attachment with [fetchId], decoded.
  static Uint8List? partBytes(MimeMessage m, String fetchId) =>
      m.getPart(fetchId)?.decodeContentBinary();
}
