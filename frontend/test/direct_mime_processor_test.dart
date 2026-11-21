import 'dart:convert';

import 'package:enough_mail_plus/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/direct/mime_processor.dart';

import 'support/mime_fixtures.dart';

MimeMessage _parse(String raw) => MimeMessage.parseFromText(raw);

void main() {
  group('headers', () {
    final h = MimeProcessor.parseHeaders(_parse(turkishMail));

    test('encoded subject and sender are decoded', () {
      expect(h.subject, 'Türkçe konu');
      expect(h.fromName, 'Şirin Ağaç');
      expect(h.fromAddress, 'sirin@example.test');
    });

    test('recipients keep their names, commas inside quotes survive', () {
      expect(h.to.map((r) => r.address), [
        'jane@example.test',
        'bob@example.test',
      ]);
      expect(h.to.first.displayName, 'Doe, Jane');
      expect(h.cc.single.address, 'cc@example.test');
      expect(h.replyTo.single.address, 'reply@example.test');
    });

    test('threading headers are normalised', () {
      expect(h.messageId, 'abc.123@example.test');
      expect(h.inReplyTo, 'prev@example.test');
      expect(h.references, 'root@example.test prev@example.test');
    });

    test('the Date header is converted to UTC', () {
      expect(
        DateTime.fromMillisecondsSinceEpoch(h.dateMs!, isUtc: true),
        DateTime.utc(2025, 10, 6, 7),
      );
    });

    test('multipart/mixed hints at attachments, plain text does not', () {
      expect(h.mayHaveAttachments, isTrue);
      expect(
        MimeProcessor.parseHeaders(_parse(bareTextMail)).mayHaveAttachments,
        isFalse,
      );
      expect(
        MimeProcessor.parseHeaders(_parse(htmlOnlyMail)).mayHaveAttachments,
        isFalse,
      );
    });

    test('a missing or broken Date gives null, never a crash', () {
      final none = MimeProcessor.parseHeaders(
        _parse('From: a@b.test\r\nSubject: x\r\n\r\nbody'),
      );
      expect(none.dateMs, isNull);
      final broken = MimeProcessor.parseHeaders(
        _parse('From: a@b.test\r\nDate: not a date\r\nSubject: x\r\n\r\nbody'),
      );
      expect(broken.dateMs, isNull);
    });

    test('line breaks cannot be smuggled through a subject', () {
      final m = _parse(
        'From: a@b.test\r\nSubject: =?UTF-8?Q?a=0D=0Ab?=\r\n\r\nbody',
      );
      expect(MimeProcessor.parseHeaders(m).subject, isNot(contains('\n')));
    });
  });

  group('body', () {
    final mail = MimeProcessor.processBody(_parse(turkishMail));

    test('legacy Turkish charsets are decoded correctly', () {
      expect(mail.text, 'Merhaba şğüıöç İĞŞ');
      expect(mail.html.html, contains('Merhaba şğı'));
    });

    test(
      'the inline logo is embedded and the tracking pixel is not loaded',
      () {
        expect(mail.html.html, contains('src="data:image/png;base64,'));
        expect(mail.html.html, isNot(contains('cid:')));
        expect(mail.html.trackingPixelHosts, ['t.example']);
        expect(mail.html.html, isNot(contains(' src="https://t.example')));
      },
    );

    test('attachments are listed with decoded names and real sizes', () {
      final names = mail.parts.map((p) => p.filename).toList();
      expect(names, ['rapor şubat.pdf', 'iletilen.eml']);
      expect(mail.parts.first.mime, 'application/pdf');
      expect(mail.parts.first.size, base64.decode('JVBERi0xLjQK').length);
      expect(mail.parts.every((p) => !p.isInline), isTrue);
      // The inline logo is part of the body, not a download.
      expect(names, isNot(contains('logo.png')));
    });

    test('the headers the app reads are kept, with lower-case keys', () {
      expect(
        mail.headers['list-unsubscribe'],
        contains('mailto:u@example.test'),
      );
      expect(mail.headers['list-unsubscribe-post'], contains('One-Click'));
      expect(mail.listUnsubscribePost, contains('One-Click'));
      expect(mail.receiptTo, 'sirin@example.test');
    });

    test('the snippet is one short clean line', () {
      expect(mail.snippet, 'Merhaba şğüıöç İĞŞ');
    });

    test('a message without MIME headers is plain text', () {
      final m = MimeProcessor.processBody(_parse(bareTextMail));
      expect(m.text, 'Merhaba,\nbu duz metin.');
      expect(m.html.html, isEmpty);
      expect(m.parts, isEmpty);
    });

    test('HTML-only mail gets a text version and loses active content', () {
      final m = MimeProcessor.processBody(_parse(htmlOnlyMail));
      expect(m.text, contains('Başlık'));
      expect(m.text, contains('Gövde metni'));
      expect(m.text, isNot(contains('x()')));
      expect(m.html.html, isNot(contains('<script')));
      expect(m.html.html, isNot(contains('color:red')));
    });

    test('an unknown charset label does not break reading', () {
      final m = MimeProcessor.processBody(_parse(unknownCharsetMail));
      expect(m.text, contains('selam dunya'));
    });

    test('an image attached but shown through cid is embedded, not listed', () {
      final m = MimeProcessor.processBody(_parse(attachedCidMail));
      expect(m.html.html, contains('src="data:image/png;base64,'));
      expect(m.parts.map((p) => p.filename), ['foto.png']);
    });

    test('an oversized inline image is listed instead of embedded', () {
      final big = base64.encode(
        List.filled(MimeProcessor.maxInlineImageBytes + 10, 7),
      );
      final raw = crlf('''From: a@b.test
Subject: big
MIME-Version: 1.0
Content-Type: multipart/related; boundary="R"

--R
Content-Type: text/html; charset=utf-8

<img src="cid:big">
--R
Content-Type: image/png
Content-ID: <big>
Content-Disposition: inline; filename="big.png"
Content-Transfer-Encoding: base64

$big
--R--
''');
      final m = MimeProcessor.processBody(_parse(raw));
      expect(m.html.html, isNot(contains('data:image')));
      expect(m.parts.map((p) => p.filename), ['big.png']);
    });

    test('allowing remote images changes only the images', () {
      final m = MimeProcessor.processBody(
        _parse(turkishMail),
        allowRemoteImages: true,
      );
      expect(m.html.remoteImagesAllowed, isTrue);
      // The 1x1 pixel stays blocked even then.
      expect(m.html.html, isNot(contains(' src="https://t.example')));
    });
  });

  group('Authentication-Results', () {
    test('pass wins over fail for the same method; hardfail reads as fail', () {
      final a = MimeProcessor.processBody(_parse(turkishMail)).authentication!;
      expect(a.authservId, 'mx.example.test');
      expect(a.spf, 'pass');
      expect(a.dkim, 'pass');
      expect(a.dmarc, 'fail');
    });

    test('nothing recognisable gives null', () {
      expect(MimeProcessor.parseAuthentication(null), isNull);
      expect(MimeProcessor.parseAuthentication(''), isNull);
      expect(MimeProcessor.parseAuthentication('mx.test; none'), isNull);
      expect(MimeProcessor.parseAuthentication('mx.test; spf=weird'), isNull);
    });

    test('values are case-insensitive', () {
      final a = MimeProcessor.parseAuthentication(
        'mx.test; SPF=Pass; DKIM=NEUTRAL',
      )!;
      expect(a.spf, 'pass');
      expect(a.dkim, 'neutral');
    });
  });

  group('signed and encrypted mail', () {
    test('S/MIME signature is recognised, nothing is claimed as verified', () {
      final m = MimeProcessor.processBody(_parse(smimeSignedMail));
      expect(m.security?.signed, 'SMime');
      expect(m.security?.encrypted, isNull);
      expect(m.text, 'imzali govde');
    });

    test('inline PGP is recognised from the text', () {
      final m = MimeProcessor.processBody(_parse(pgpInlineMail));
      expect(m.security?.signed, 'OpenPgp');
    });

    test('ordinary mail has no security marker', () {
      expect(MimeProcessor.processBody(_parse(turkishMail)).security, isNull);
    });

    test('S/MIME encrypted body is flagged', () {
      final m = _parse(
        'From: a@b.test\r\nContent-Type: application/pkcs7-mime; smime-type=enveloped-data\r\n\r\nAAAA',
      );
      expect(MimeProcessor.detectSecurity(m, '')?.encrypted, 'SMime');
    });
  });

  test('the original source is returned exactly', () {
    final m = _parse(turkishMail);
    expect(m.renderMessage(), turkishMail);
  });
}
