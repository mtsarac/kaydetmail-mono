import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/direct/mail_recipients.dart';
import 'package:kaydetmail/services/direct/mail_threading.dart';

// Mirrors backend/tests/MailClient.Tests/ConversationThreadTests.cs and
// ComposeRecipientTests.cs so a message threads and replies the same way on
// this device as it does through the server.
void main() {
  group('normalizeSubject', () {
    const cases = {
      'Re: Yıllık Rapor': 'Yıllık Rapor',
      'FW: Mail: özet': 'Mail: özet',
      'RE: FWD: SV: TR: zincir': 'zincir',
      'Vv: küçük harf': 'küçük harf',
      'Ynt: konu': 'konu',
      'İLT: konu': 'konu',
      'AW: WG: konu': 'konu',
      '  Yıllık   Rapor  ': 'Yıllık Rapor',
      'Sorun: gündüz': 'Sorun: gündüz',
      '': '',
      'Re:': '',
    };
    for (final entry in cases.entries) {
      test('"${entry.key}" -> "${entry.value}"', () {
        expect(MailThreading.normalizeSubject(entry.key), entry.value);
      });
    }

    test(
      'null is empty',
      () => expect(MailThreading.normalizeSubject(null), ''),
    );
  });

  group('message ids', () {
    test('angle brackets are stripped, idempotently', () {
      for (final (input, expected) in [
        ('  <abc@ornek.test>  ', 'abc@ornek.test'),
        ('bare@ornek.test', 'bare@ornek.test'),
        (null, ''),
      ]) {
        expect(MailThreading.normalizeMessageId(input), expected);
        expect(MailThreading.normalizeMessageId(expected), expected);
      }
    });

    test('References split on whitespace and commas, de-duplicated', () {
      expect(MailThreading.parseReferences('<a@x> <b@x> a@x\t<c@x>'), [
        'a@x',
        'b@x',
        'c@x',
      ]);
      expect(MailThreading.parseReferences('<a@x>,<b@x>'), ['a@x', 'b@x']);
      expect(MailThreading.parseReferences(null), isEmpty);
    });
  });

  group('replyHeaders', () {
    test('In-Reply-To is the source, References extends its chain', () {
      final h = MailThreading.replyHeaders(
        '<source@example.test>',
        '<prior@example.test>',
      );
      expect(h.inReplyTo, 'source@example.test');
      expect(h.references, 'prior@example.test source@example.test');
    });

    test('a source already in its own chain is not repeated', () {
      final h = MailThreading.replyHeaders('<a@x>', '<b@x> <a@x>');
      expect(h.references, 'b@x a@x');
    });

    test('a source without ids yields no headers', () {
      final h = MailThreading.replyHeaders(null, null);
      expect(h.inReplyTo, '');
      expect(h.references, '');
    });
  });

  group('recipients', () {
    List<String> addr(List<MailRecipient> l) => [for (final r in l) r.address];

    test('reply uses Reply-To when present', () {
      final r = MailRecipients.reply(
        from: const [MailRecipient('from@example.test')],
        replyTo: const [MailRecipient('reply@example.test')],
      );
      expect(addr(r.to), ['reply@example.test']);
    });

    test('reply falls back to From', () {
      final r = MailRecipients.reply(
        from: const [MailRecipient('from@example.test')],
      );
      expect(addr(r.to), ['from@example.test']);
    });

    test('reply-all drops own addresses, de-duplicates, hides Bcc', () {
      final r = MailRecipients.replyAll(
        from: const [MailRecipient('me@example.test')],
        replyTo: const [MailRecipient('reply@example.test')],
        to: const [
          MailRecipient('me@example.test'),
          MailRecipient('to@example.test'),
        ],
        cc: const [
          MailRecipient('reply@example.test'),
          MailRecipient('cc@example.test'),
        ],
        ownAddresses: const ['ME@example.test'],
      );
      expect(addr(r.to), ['reply@example.test', 'to@example.test']);
      expect(addr(r.cc), ['cc@example.test']);
      expect(addr(r.bcc), isEmpty);
    });

    test('reply-all also drops the user\'s other identities', () {
      final r = MailRecipients.replyAll(
        from: const [MailRecipient('boss@corp.test')],
        to: const [
          MailRecipient('me@example.test'),
          MailRecipient('alias@example.test'),
          MailRecipient('team@corp.test'),
        ],
        ownAddresses: const ['me@example.test', 'alias@example.test'],
      );
      expect(addr(r.to), ['boss@corp.test', 'team@corp.test']);
    });

    test('unusable addresses are skipped, names are kept', () {
      final r = MailRecipients.reply(
        from: const [
          MailRecipient('not an address'),
          MailRecipient('ok@example.test', 'Ok'),
        ],
      );
      expect(addr(r.to), ['ok@example.test']);
      expect(r.to.single.displayName, 'Ok');
    });
  });
}
