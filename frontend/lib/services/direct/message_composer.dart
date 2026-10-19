import 'dart:math';
import 'dart:typed_data';

import 'package:enough_mail_plus/enough_mail.dart'
    show MailAddress, MediaType, MessageBuilder;

import 'direct_errors.dart';
import 'mail_recipients.dart';

/// One file to attach.
class ComposeAttachment {
  const ComposeAttachment({
    required this.name,
    required this.bytes,
    this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String? mimeType;
}

/// What the user wrote, ready to become a message.
class ComposeInput {
  const ComposeInput({
    required this.fromAddress,
    this.fromName = '',
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.bodyText = '',
    this.bodyHtml,
    this.attachments = const [],
    this.replyTo,
    this.inReplyTo,
    this.references,
    this.requestReadReceipt = false,
    this.messageId,
    this.date,
    this.isDraft = false,
  });

  final String fromAddress;
  final String fromName;
  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String bodyText;
  final String? bodyHtml;
  final List<ComposeAttachment> attachments;
  final String? replyTo;

  /// Message-ID of the mail being answered, with its angle brackets.
  final String? inReplyTo;

  /// The `References` chain to continue.
  final String? references;
  final bool requestReadReceipt;

  /// Fixed when the same message must be built again (a retry, a Sent copy).
  final String? messageId;
  final DateTime? date;

  /// A draft may lack recipients.
  final bool isDraft;
}

/// A message ready for the wire and for filing.
class ComposedMessage {
  const ComposedMessage({
    required this.messageId,
    required this.source,
    required this.sourceForCopy,
    required this.envelopeFrom,
    required this.envelopeRecipients,
  });

  /// `<id@host>`.
  final String messageId;

  /// RFC 5322 text to submit: no `Bcc` header.
  final String source;

  /// The same message as kept in Sent, with its `Bcc` header when there were
  /// hidden recipients (the sender wants to see whom it went to).
  final String sourceForCopy;
  final String envelopeFrom;

  /// To, Cc and Bcc, each address once.
  final List<String> envelopeRecipients;

  int get size => source.length;
}

/// Builds messages. Everything is `UTF-8`, transfer-encoded so the result is
/// pure 7-bit text that any relay accepts.
class MessageComposer {
  const MessageComposer._();

  static final _random = Random.secure();

  /// A fresh Message-ID under the sender's own domain.
  static String newMessageId(String fromAddress) {
    final at = fromAddress.lastIndexOf('@');
    final host = at < 0 || at == fromAddress.length - 1
        ? 'kaydetmail.invalid'
        : fromAddress.substring(at + 1);
    final id = [
      for (var i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    return '<$id@$host>';
  }

  static MailAddress _address(String raw) {
    final text = raw.trim();
    if (!MailRecipients.isUsableAddress(text)) {
      if (!text.contains('<')) {
        throw DirectMailException(DirectErrorKind.smtpRecipientRejected);
      }
      try {
        final parsed = MailAddress.parse(text);
        if (MailRecipients.isUsableAddress(parsed.email)) return parsed;
      } on Object {
        // Falls through to the error below.
      }
      throw DirectMailException(DirectErrorKind.smtpRecipientRejected);
    }
    return MailAddress(null, text);
  }

  /// Splits an RFC 5322 header value and rejects anything that could start
  /// another header.
  static String _header(String value) =>
      value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

  static ComposedMessage compose(ComposeInput input) {
    final to = input.to.map(_address).toList();
    final cc = input.cc.map(_address).toList();
    final bcc = input.bcc.map(_address).toList();
    if (!input.isDraft && to.isEmpty && cc.isEmpty && bcc.isEmpty) {
      throw DirectMailException(DirectErrorKind.smtpRecipientRejected);
    }
    if (!MailRecipients.isUsableAddress(input.fromAddress)) {
      throw DirectMailException(DirectErrorKind.smtpSenderRejected);
    }
    final messageId = input.messageId ?? newMessageId(input.fromAddress);
    final date = input.date ?? DateTime.now();

    String build({required bool withBcc}) {
      final builder = MessageBuilder()
        ..from = [MailAddress(_header(input.fromName), input.fromAddress)]
        ..to = to
        ..cc = cc
        ..bcc = withBcc ? bcc : null
        ..subject = _header(input.subject)
        ..date = date
        ..messageId = messageId;
      final inReplyTo = input.inReplyTo;
      if (inReplyTo != null && inReplyTo.trim().isNotEmpty) {
        builder.setHeader('In-Reply-To', _header(inReplyTo));
        final chain = [
          if ((input.references ?? '').trim().isNotEmpty)
            _header(input.references!),
          _header(inReplyTo),
        ].join(' ');
        builder.setHeader('References', chain);
      }
      final replyTo = input.replyTo;
      if (replyTo != null && replyTo.trim().isNotEmpty) {
        builder.setMailAddressHeader('Reply-To', [_address(replyTo)]);
      }
      if (input.requestReadReceipt) {
        builder.requestReadReceipt(
          recipient: MailAddress(null, input.fromAddress),
        );
      }
      final html = input.bodyHtml;
      if (html != null && html.trim().isNotEmpty) {
        builder.addMultipartAlternative(
          plainText: input.bodyText,
          htmlText: html,
        );
      } else {
        builder.text = input.bodyText;
      }
      for (final attachment in input.attachments) {
        builder.addBinary(
          attachment.bytes,
          MediaType.fromText(
            (attachment.mimeType ?? '').contains('/')
                ? attachment.mimeType!
                : 'application/octet-stream',
          ),
          filename: _header(attachment.name),
        );
      }
      return builder.buildMimeMessage().renderMessage();
    }

    final source = build(withBcc: false);
    final recipients = <String>[];
    final seen = <String>{};
    for (final a in [...to, ...cc, ...bcc]) {
      if (seen.add(a.email.toLowerCase())) recipients.add(a.email);
    }
    return ComposedMessage(
      messageId: messageId,
      source: source,
      sourceForCopy: bcc.isEmpty ? source : build(withBcc: true),
      envelopeFrom: input.fromAddress,
      envelopeRecipients: recipients,
    );
  }
}
