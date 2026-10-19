import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail_plus/enough_mail.dart' show MimeMessage;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/message_composer.dart';
import 'package:kaydetmail/services/direct/mime_processor.dart';

ComposedMessage _compose({
  List<String> to = const ['ali@example.org'],
  List<String> cc = const [],
  List<String> bcc = const [],
  String subject = 'Toplantı',
  String text = 'Merhaba şğüıöç',
  String? html,
  List<ComposeAttachment> attachments = const [],
  String? inReplyTo,
  String? references,
  bool receipt = false,
  String? replyTo,
}) => MessageComposer.compose(
  ComposeInput(
    fromAddress: 'ben@example.com',
    fromName: 'Şirin Ağaç',
    to: to,
    cc: cc,
    bcc: bcc,
    subject: subject,
    bodyText: text,
    bodyHtml: html,
    attachments: attachments,
    inReplyTo: inReplyTo,
    references: references,
    requestReadReceipt: receipt,
    replyTo: replyTo,
    date: DateTime.utc(2025, 10, 6, 12),
  ),
);

void main() {
  test('Turkish text and names survive a round trip through the reader', () {
    final message = _compose();
    final parsed = MimeMessage.parseFromText(message.source);
    final headers = MimeProcessor.parseHeaders(parsed);
    expect(headers.subject, 'Toplantı');
    expect(headers.fromName, 'Şirin Ağaç');
    expect(headers.fromAddress, 'ben@example.com');
    expect(headers.messageId, message.messageId.replaceAll(RegExp('[<>]'), ''));
    final processed = MimeProcessor.processBody(parsed);
    expect(processed.text, contains('Merhaba şğüıöç'));
  });

  test('the submitted text is plain 7-bit and never carries Bcc', () {
    final message = _compose(bcc: ['gizli@example.net']);
    expect(message.source.codeUnits.every((c) => c < 128), isTrue);
    expect(message.source.toLowerCase(), isNot(contains('bcc:')));
    expect(message.source, isNot(contains('gizli@example.net')));
    expect(message.sourceForCopy.toLowerCase(), contains('bcc:'));
    expect(message.sourceForCopy, contains('gizli@example.net'));
    expect(message.envelopeRecipients, [
      'ali@example.org',
      'gizli@example.net',
    ]);
  });

  test('every recipient is in the envelope once', () {
    final message = _compose(
      to: ['a@example.org', 'A@example.org'],
      cc: ['a@example.org', 'b@example.org'],
      bcc: ['c@example.org'],
    );
    expect(message.envelopeRecipients, [
      'a@example.org',
      'b@example.org',
      'c@example.org',
    ]);
  });

  test('a reply continues the thread', () {
    final message = _compose(
      inReplyTo: '<m2@example.org>',
      references: '<m0@example.org> <m1@example.org>',
    );
    final parsed = MimeMessage.parseFromText(message.source);
    final headers = MimeProcessor.parseHeaders(parsed);
    expect(headers.inReplyTo, 'm2@example.org');
    expect(
      headers.references,
      allOf(
        contains('m0@example.org'),
        contains('m1@example.org'),
        contains('m2@example.org'),
      ),
    );
  });

  test('HTML goes out with a plain alternative', () {
    final message = _compose(text: 'düz', html: '<p>zengin <b>metin</b></p>');
    final parsed = MimeMessage.parseFromText(message.source);
    final processed = MimeProcessor.processBody(parsed);
    expect(processed.text, contains('düz'));
    expect(processed.html.html, contains('<b>metin</b>'));
  });

  test('attachments keep their name, type and bytes', () {
    final bytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
    final message = _compose(
      attachments: [
        ComposeAttachment(
          name: 'rapor şubat.pdf',
          bytes: bytes,
          mimeType: 'application/pdf',
        ),
        ComposeAttachment(name: 'ham', bytes: Uint8List.fromList([1, 2, 3])),
      ],
      html: '<p>ekli</p>',
    );
    final parsed = MimeMessage.parseFromText(message.source);
    final processed = MimeProcessor.processBody(parsed);
    expect(processed.parts.map((p) => p.filename), ['rapor şubat.pdf', 'ham']);
    expect(processed.parts.first.mime, 'application/pdf');
    expect(processed.parts.last.mime, 'application/octet-stream');
    final stored = MimeProcessor.partBytes(
      parsed,
      processed.parts.first.partId,
    );
    expect(stored, bytes);
  });

  test('a read receipt and a Reply-To are asked for in the headers', () {
    final message = _compose(receipt: true, replyTo: 'yanit@example.com');
    final parsed = MimeMessage.parseFromText(message.source);
    expect(
      parsed.getHeaderValue('disposition-notification-to'),
      contains('ben@example.com'),
    );
    expect(parsed.getHeaderValue('reply-to'), contains('yanit@example.com'));
  });

  test('a subject cannot smuggle another header in', () {
    final message = _compose(subject: 'merhaba\r\nBcc: kurban@example.net');
    expect(message.source.toLowerCase(), isNot(contains('\r\nbcc:')));
    expect(message.envelopeRecipients, ['ali@example.org']);
  });

  test(
    'the message id is under the sender\'s domain and stable when given',
    () {
      final first = _compose();
      expect(
        first.messageId,
        matches(RegExp(r'^<[0-9a-f]{32}@example\.com>$')),
      );
      final again = MessageComposer.compose(
        ComposeInput(
          fromAddress: 'ben@example.com',
          to: const ['ali@example.org'],
          messageId: first.messageId,
          date: DateTime.utc(2025, 10, 6, 12),
        ),
      );
      expect(again.messageId, first.messageId);
    },
  );

  test('unusable addresses are refused before anything is sent', () {
    expect(
      () => _compose(to: ['not an address']),
      throwsA(
        isA<DirectMailException>().having(
          (e) => e.code,
          'code',
          'smtp_recipient_rejected',
        ),
      ),
    );
    expect(
      () => _compose(to: [], cc: [], bcc: []),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => MessageComposer.compose(
        const ComposeInput(fromAddress: 'broken', to: ['a@b.co']),
      ),
      throwsA(
        isA<DirectMailException>().having(
          (e) => e.code,
          'code',
          'smtp_sender_rejected',
        ),
      ),
    );
  });

  test('a draft may have no recipients', () {
    final draft = MessageComposer.compose(
      const ComposeInput(
        fromAddress: 'ben@example.com',
        isDraft: true,
        subject: 'Taslak',
      ),
    );
    expect(
      MimeProcessor.parseHeaders(MimeMessage.parseFromText(draft.source))
          .subject,
      'Taslak',
    );
    expect(draft.envelopeRecipients, isEmpty);
  });

  test('a name with a comma or quote is encoded properly', () {
    final message = MessageComposer.compose(
      const ComposeInput(
        fromAddress: 'ben@example.com',
        fromName: 'Doe, "Jane"',
        to: ['Ali Veli <ali@example.org>'],
        subject: 'x',
      ),
    );
    final headers = MimeProcessor.parseHeaders(
      MimeMessage.parseFromText(message.source),
    );
    expect(headers.fromName, 'Doe, "Jane"');
    expect(headers.to.single.address, 'ali@example.org');
    expect(headers.to.single.displayName, 'Ali Veli');
    expect(utf8.encode(message.source).length, message.source.length);
  });
}
