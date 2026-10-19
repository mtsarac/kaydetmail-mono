import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail_plus/enough_mail.dart' show MimeMessage;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/email.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/models/mail_signature.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/mime_processor.dart';

import 'support/direct_rig.dart';
import 'support/mime_fixtures.dart';

MailFolder _resolve(String id) => MailFolder.inbox;

Matcher _code(String code) =>
    isA<ApiException>().having((e) => e.code, 'code', code);

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  Future<List<String>> open(String type) async {
    final folder = (await rig.gateway.getFolders()).firstWhere(
      (f) => f.type == type,
    );
    final page = await rig.gateway.getMails(
      folderId: folder.id,
      resolveFolder: _resolve,
    );
    return [for (final e in page.items) e.id];
  }

  MimeMessage received(int index) =>
      MimeMessage.parseFromText(rig.smtp.sent[index].source);

  group('sending', () {
    test('submits the message and files a copy in Sent', () async {
      rig = DirectRig();
      rig.imap.addFolder('Sent', use: FolderRole.sent);
      await open('Sent'); // listed before: the copy appears at once
      final result = await rig.gateway.sendMail(
        to: ['ali@example.org'],
        bcc: ['gizli@example.net'],
        subject: 'Toplantı',
        bodyText: 'Yarın saat 10',
        idempotencyKey: 'k1',
      );
      expect(result.sent, isTrue);
      expect(result.sentCopySaved, isTrue);
      expect(result.mailId, isNotNull);

      final message = rig.smtp.sent.single;
      expect(message.envelopeFrom, rigAddress);
      expect(message.envelopeRecipients, [
        'ali@example.org',
        'gizli@example.net',
      ]);
      expect(message.source.toLowerCase(), isNot(contains('bcc:')));

      final copy = rig.imap.folders['Sent']!.messages.values.single;
      expect(copy.flags, contains(r'\Seen'));
      expect(
        copy.raw,
        contains('gizli@example.net'),
        reason: 'the sender keeps the Bcc line',
      );
      final mail = await rig.gateway.getMail(
        result.mailId!,
        resolveFolder: _resolve,
      );
      expect(mail.subject, 'Toplantı');
    });

    test('creates the Sent folder when there is none', () async {
      rig = DirectRig();
      final result = await rig.gateway.sendMail(
        to: ['ali@example.org'],
        subject: 's',
        idempotencyKey: 'k1',
      );
      expect(result.sentCopySaved, isTrue);
      expect(rig.imap.folders.containsKey('Sent'), isTrue);
      expect(rig.imap.folders['Sent']!.messages, hasLength(1));
    });

    test(
      'a retry with the same key delivers once and answers the same',
      () async {
        rig = DirectRig();
        final first = await rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        );
        final again = await rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        );
        expect(rig.smtp.sent, hasLength(1));
        expect(again.sent, isTrue);
        expect(again.mailId, first.mailId);
        expect(rig.imap.folders['Sent']!.messages, hasLength(1));
      },
    );

    test('while one attempt is running, the same key is refused', () async {
      rig = DirectRig();
      rig.smtp.gate = Completer<void>();
      final running = rig.gateway.sendMail(
        to: ['a@example.org'],
        subject: 's',
        idempotencyKey: 'k1',
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        ),
        throwsA(_code('send_in_progress')),
      );
      rig.smtp.gate!.complete();
      expect((await running).sent, isTrue);
      expect(rig.smtp.sent, hasLength(1));
    });

    test('a definite refusal can be retried under the same key', () async {
      rig = DirectRig();
      rig.smtp.failures.add(
        DirectMailException(DirectErrorKind.smtpRecipientRejected),
      );
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        ),
        throwsA(_code('smtp_recipient_rejected')),
      );
      expect(
        rig.imap.folders.containsKey('Sent'),
        isFalse,
        reason: 'nothing was sent, nothing filed',
      );
      final result = await rig.gateway.sendMail(
        to: ['b@example.org'],
        subject: 's',
        idempotencyKey: 'k1',
      );
      expect(result.sent, isTrue);
      expect(rig.smtp.attempts, 2);
    });

    test('an unknown outcome is never repeated by itself', () async {
      rig = DirectRig();
      rig.smtp
        ..deliverThenFail = true
        ..failures.add(DirectMailException(DirectErrorKind.deliveryUncertain));
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        ),
        throwsA(_code('delivery_unknown')),
      );
      expect(rig.smtp.sent, hasLength(1), reason: 'the server did get it');
      expect(rig.imap.folders.containsKey('Sent'), isFalse);

      // The outbox retrying: refused without touching the server.
      final attempts = rig.smtp.attempts;
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        ),
        throwsA(_code('delivery_unknown')),
      );
      expect(rig.smtp.attempts, attempts);

      // The user deciding to send again is a new attempt with a new key.
      final fresh = await rig.gateway.sendMail(
        to: ['a@example.org'],
        subject: 's',
        idempotencyKey: 'k2',
      );
      expect(fresh.sent, isTrue);
    });

    test('an attempt cut off by the app closing counts as unknown', () async {
      rig = DirectRig();
      // What a previous process left behind: started, never finished.
      rig.store.db.execute(
        "INSERT INTO d_sends (account_id, send_key, state, message_id, started_ms, updated_ms) "
        "VALUES ('$rigAccountId', 'k1', 'sending', '<x@example.com>', 1, 1)",
      );
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        ),
        throwsA(_code('delivery_unknown')),
      );
      expect(rig.smtp.attempts, 0);
    });

    test(
      'a refused password stops further sends until a new one is given',
      () async {
        rig = DirectRig();
        rig.smtp.failures.add(DirectMailException(DirectErrorKind.authFailed));
        await expectLater(
          rig.gateway.sendMail(
            to: ['a@example.org'],
            subject: 's',
            idempotencyKey: 'k1',
          ),
          throwsA(_code('auth_failed')),
        );
        expect(
          (await rig.gateway.getAccount()).status.name,
          'needsReauthentication',
        );
        final attempts = rig.smtp.attempts;
        await expectLater(
          rig.gateway.sendMail(
            to: ['a@example.org'],
            subject: 's',
            idempotencyKey: 'k2',
          ),
          throwsA(_code('auth_failed')),
        );
        expect(
          rig.smtp.attempts,
          attempts,
          reason: 'the refused password is not tried again',
        );

        await rig.gateway.reconnect(password: 'yeni');
        expect((await rig.gateway.getAccount()).status.name, 'active');
        expect(
          (await rig.gateway.sendMail(
            to: ['a@example.org'],
            subject: 's',
            idempotencyKey: 'k3',
          )).sent,
          isTrue,
        );
      },
    );

    test('a copy that cannot be filed does not undo the send', () async {
      rig = DirectRig();
      rig.imap.addFolder('Sent', use: FolderRole.sent);
      await open('Sent');
      rig.imap.failNext(
        'append',
        DirectMailException(DirectErrorKind.hostUnreachable),
      );
      final result = await rig.gateway.sendMail(
        to: ['a@example.org'],
        subject: 's',
        idempotencyKey: 'k1',
      );
      expect(result.sent, isTrue);
      expect(result.sentCopySaved, isFalse);
      expect(result.warning, 'sent_copy_failed');
      expect(rig.smtp.sent, hasLength(1));
    });

    test(
      'no copy is filed when the account says so, or when the server does it',
      () async {
        rig = DirectRig(saveSentCopy: false);
        final first = await rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        );
        expect(first.sentCopySaved, isFalse);
        expect(rig.imap.folders.containsKey('Sent'), isFalse);
        await rig.dispose();

        rig = DirectRig(smtpHost: 'smtp.gmail.com');
        rig.imap.addFolder('Sent', use: FolderRole.sent);
        final second = await rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          idempotencyKey: 'k1',
        );
        expect(second.sentCopySaved, isTrue);
        expect(
          rig.imap.folders['Sent']!.messages,
          isEmpty,
          reason: 'Gmail files its own copy',
        );
      },
    );

    test(
      'a reply carries the thread headers and marks the original answered',
      () async {
        rig = DirectRig();
        final uid = rig.imap.add(
          'INBOX',
          rigMail('orig', subject: 'Plan', references: '<root@example.org>'),
        );
        final ids = await open('Inbox');
        await rig.gateway.sendMail(
          to: ['ayse@example.org'],
          subject: 'Re: Plan',
          bodyText: 'tamam',
          replySourceMailId: ids.single,
          idempotencyKey: 'k1',
        );
        final headers = MimeProcessor.parseHeaders(received(0));
        expect(headers.inReplyTo, 'orig@example.org');
        expect(
          headers.references,
          allOf(contains('root@example.org'), contains('orig@example.org')),
        );
        expect(
          rig.imap.folders['INBOX']!.messages[uid]!.flags,
          contains(r'\Answered'),
        );
        expect(rig.store.message(rigAccountId, ids.single)!.isAnswered, isTrue);
      },
    );

    test('a forward marks the original forwarded', () async {
      rig = DirectRig();
      final uid = rig.imap.add('INBOX', rigMail('orig', subject: 'Plan'));
      final ids = await open('Inbox');
      await rig.gateway.sendMail(
        to: ['kemal@example.org'],
        subject: 'Fwd: Plan',
        replySourceMailId: ids.single,
        idempotencyKey: 'k1',
      );
      expect(
        rig.imap.folders['INBOX']!.messages[uid]!.flags,
        contains(r'$Forwarded'),
      );
      expect(rig.store.message(rigAccountId, ids.single)!.isForwarded, isTrue);
    });

    test(
      'sending as another identity uses its address, name and reply-to',
      () async {
        rig = DirectRig();
        final identity = await rig.gateway.createIdentity(
          const MailIdentity(
            id: '',
            emailAddress: 'info@example.com',
            displayName: 'Destek',
            replyTo: 'yanit@example.com',
          ),
        );
        await rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          identityId: identity.id,
          idempotencyKey: 'k1',
        );
        expect(rig.smtp.sent.single.envelopeFrom, 'info@example.com');
        final headers = MimeProcessor.parseHeaders(received(0));
        expect(headers.fromName, 'Destek');
        expect(headers.fromAddress, 'info@example.com');
        expect(
          received(0).getHeaderValue('reply-to'),
          contains('yanit@example.com'),
        );
        await expectLater(
          rig.gateway.sendMail(
            to: ['a@example.org'],
            subject: 's',
            identityId: 'i:nope',
            idempotencyKey: 'k2',
          ),
          throwsA(_code('identity_not_found')),
        );
      },
    );

    test('a read receipt is requested in the header', () async {
      rig = DirectRig();
      await rig.gateway.sendMail(
        to: ['a@example.org'],
        subject: 's',
        requestReadReceipt: true,
        idempotencyKey: 'k1',
      );
      expect(
        received(0).getHeaderValue('disposition-notification-to'),
        contains(rigAddress),
      );
    });

    test('attachments are sent; ones without content are left out', () async {
      rig = DirectRig();
      final bytes = Uint8List.fromList(List.generate(2000, (i) => i % 251));
      await rig.gateway.sendMail(
        to: ['a@example.org'],
        subject: 's',
        bodyText: 'ekte',
        attachments: [
          Attachment(
            name: 'veri.bin',
            sizeBytes: bytes.length,
            bytes: bytes,
            mimeType: 'application/octet-stream',
          ),
          const Attachment(name: 'uzakta.pdf', sizeBytes: 10, id: '2'),
        ],
        idempotencyKey: 'k1',
      );
      final parsed = received(0);
      final processed = MimeProcessor.processBody(parsed);
      expect(processed.parts.map((p) => p.filename), ['veri.bin']);
      expect(
        MimeProcessor.partBytes(parsed, processed.parts.single.partId),
        bytes,
      );
    });

    test('limits follow what the server announced and are enforced', () async {
      rig = DirectRig();
      expect(
        (await rig.gateway.getComposeLimits()).maxMessageAttachmentBytes,
        18 * 1024 * 1024,
      );
      rig.smtp.limit = 2 * 1024 * 1024;
      await rig.gateway.sendMail(
        to: ['a@example.org'],
        subject: 's',
        idempotencyKey: 'k1',
      );
      final limits = await rig.gateway.getComposeLimits();
      expect(
        limits.maxMessageAttachmentBytes,
        (2 * 1024 * 1024 * 0.72).floor(),
      );

      final big = Uint8List(limits.maxMessageAttachmentBytes + 1);
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          attachments: [
            Attachment(name: 'b', sizeBytes: big.length, bytes: big),
          ],
          idempotencyKey: 'k2',
        ),
        throwsA(_code('attachment_too_large')),
      );
      await expectLater(
        rig.gateway.sendMail(
          to: ['a@example.org'],
          subject: 's',
          attachments: [
            for (var i = 0; i < 26; i++)
              Attachment(name: 'a$i', sizeBytes: 1, bytes: Uint8List(1)),
          ],
          idempotencyKey: 'k3',
        ),
        throwsA(_code('too_many_attachments')),
      );
    });

    test(
      'no recipients and bad addresses are refused before the server',
      () async {
        rig = DirectRig();
        await expectLater(
          rig.gateway.sendMail(to: [], subject: 's', idempotencyKey: 'k1'),
          throwsA(isA<DirectMailException>()),
        );
        await expectLater(
          rig.gateway.sendMail(
            to: ['nope'],
            subject: 's',
            idempotencyKey: 'k2',
          ),
          throwsA(_code('smtp_recipient_rejected')),
        );
        expect(rig.smtp.attempts, 0);
      },
    );
  });

  group('drafts', () {
    test('are filed in Drafts, listed, and readable with their Bcc', () async {
      rig = DirectRig();
      rig.imap.addFolder('Drafts', use: FolderRole.drafts);
      final result = await rig.gateway.createDraft(
        to: ['ali@example.org'],
        bcc: ['gizli@example.net'],
        subject: 'Taslak konu',
        bodyText: 'yarım kalan',
      );
      expect(result.mailId, isNotNull);
      final stored = rig.imap.folders['Drafts']!.messages.values.single;
      expect(stored.flags, containsAll([r'\Draft', r'\Seen']));
      final draft = await rig.gateway.getDraft(
        result.mailId!,
        resolveFolder: _resolve,
      );
      expect(draft.subject, 'Taslak konu');
      expect(draft.recipients, ['ali@example.org']);
      expect(draft.bcc, ['gizli@example.net']);
      expect(draft.bodyText, contains('yarım kalan'));
    });

    test('a draft may have no recipients yet', () async {
      rig = DirectRig();
      final result = await rig.gateway.createDraft(to: [], subject: 'Boş');
      expect(result.mailId, isNotNull);
    });

    test('updating files the new version and removes the old', () async {
      rig = DirectRig();
      rig.imap.addFolder('Drafts', use: FolderRole.drafts);
      final first = await rig.gateway.createDraft(
        to: ['a@example.org'],
        subject: 'v1',
      );
      final second = await rig.gateway.updateDraft(
        first.mailId!,
        to: ['a@example.org'],
        subject: 'v2',
        bodyText: 'daha çok',
      );
      expect(second.mailId, isNot(first.mailId));
      expect(second.warning, isNull);
      final messages = rig.imap.folders['Drafts']!.messages.values;
      expect(messages, hasLength(1));
      expect(messages.single.raw, contains('v2'));
      expect(rig.store.message(rigAccountId, first.mailId!), isNull);
      await expectLater(
        rig.gateway.getDraft(first.mailId!, resolveFolder: _resolve),
        throwsA(_code('mail_not_found')),
      );
    });

    test('deleting removes it from the server', () async {
      rig = DirectRig();
      rig.imap.addFolder('Drafts', use: FolderRole.drafts);
      final draft = await rig.gateway.createDraft(
        to: ['a@example.org'],
        subject: 'x',
      );
      await rig.gateway.deleteDraft(draft.mailId!);
      expect(rig.imap.folders['Drafts']!.messages, isEmpty);
    });

    test('a mail that is not a draft is not treated as one', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'));
      final ids = await open('Inbox');
      await expectLater(
        rig.gateway.getDraft(ids.single, resolveFolder: _resolve),
        throwsA(_code('mail_not_draft')),
      );
      await expectLater(
        rig.gateway.deleteDraft(ids.single),
        throwsA(_code('mail_not_draft')),
      );
      await expectLater(
        rig.gateway.sendDraft(ids.single, idempotencyKey: 'k'),
        throwsA(_code('mail_not_draft')),
      );
    });

    test('sending a draft delivers it without Bcc, files a copy, removes the draft', () async {
      rig = DirectRig();
      rig.imap.addFolder('Drafts', use: FolderRole.drafts);
      final draft = await rig.gateway.createDraft(
        to: ['ali@example.org'],
        bcc: ['gizli@example.net'],
        subject: 'Giden taslak',
        bodyText: 'merhaba',
      );
      final result = await rig.gateway.sendDraft(
        draft.mailId!,
        idempotencyKey: 'k1',
      );
      expect(result.sent, isTrue);
      expect(result.draftRemoved, isTrue);
      expect(result.sentCopySaved, isTrue);

      final message = rig.smtp.sent.single;
      expect(message.envelopeRecipients, [
        'ali@example.org',
        'gizli@example.net',
      ]);
      expect(message.source.toLowerCase(), isNot(contains('bcc:')));
      expect(received(0).decodeSubject(), 'Giden taslak');
      expect(rig.imap.folders['Drafts']!.messages, isEmpty);
      expect(
        rig.imap.folders['Sent']!.messages.values.single.raw,
        contains('gizli@example.net'),
      );

      // The same key again does not send twice.
      final again = await rig.gateway.sendDraft(
        draft.mailId!,
        idempotencyKey: 'k1',
      );
      expect(again.sent, isTrue);
      expect(rig.smtp.sent, hasLength(1));
    });

    test(
      'a draft that cannot be removed after sending is still a sent mail',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Drafts', use: FolderRole.drafts);
        final draft = await rig.gateway.createDraft(
          to: ['a@example.org'],
          subject: 'x',
        );
        rig.imap.failNext(
          'expunge',
          DirectMailException(DirectErrorKind.imapCommandFailed),
        );
        final result = await rig.gateway.sendDraft(
          draft.mailId!,
          idempotencyKey: 'k1',
        );
        expect(result.sent, isTrue);
        expect(result.draftRemoved, isFalse);
        expect(rig.smtp.sent, hasLength(1));
      },
    );

    test('a draft without recipients cannot be sent', () async {
      rig = DirectRig();
      final draft = await rig.gateway.createDraft(to: [], subject: 'x');
      await expectLater(
        rig.gateway.sendDraft(draft.mailId!, idempotencyKey: 'k1'),
        throwsA(_code('smtp_recipient_rejected')),
      );
      expect(rig.smtp.attempts, 0);
    });
  });

  group('starting a reply or forward', () {
    Future<String> sourceMail() async {
      rig.imap.add(
        'INBOX',
        [
          'From: =?UTF-8?B?${base64.encode(utf8.encode('Şirin Ağaç'))}?= <sirin@example.org>',
          'Reply-To: yanit@example.org',
          'To: $rigAddress, ek@example.org',
          'Cc: kopya@example.org, $rigAddress',
          'Subject: Plan',
          'Message-ID: <src@example.org>',
          'References: <root@example.org>',
          'Date: Mon, 6 Oct 2025 10:00:00 +0000',
          'MIME-Version: 1.0',
          'Content-Type: text/plain; charset=utf-8',
          '',
          'metin',
          '',
        ].join('\r\n'),
      );
      return (await open('Inbox')).single;
    }

    test('reply goes to Reply-To, with the thread continued', () async {
      rig = DirectRig();
      final id = await sourceMail();
      final prefill = await rig.gateway.getComposePrefill(id, 'reply');
      expect(prefill.to, ['yanit@example.org']);
      expect(prefill.cc, isEmpty);
      expect(prefill.suggestedSubject, 'Re: Plan');
      expect(prefill.inReplyToMessageId, '<src@example.org>');
      expect(prefill.references, '<root@example.org> <src@example.org>');
      expect(prefill.originalFrom, 'Şirin Ağaç <sirin@example.org>');
      expect(prefill.originalSubject, 'Plan');
    });

    test('reply all drops the user, keeps everyone else once', () async {
      rig = DirectRig();
      final id = await sourceMail();
      final prefill = await rig.gateway.getComposePrefill(id, 'reply-all');
      expect(prefill.to, ['yanit@example.org', 'ek@example.org']);
      expect(prefill.cc, ['kopya@example.org']);
    });

    test('reply all also drops the user\'s other identities', () async {
      rig = DirectRig();
      await rig.gateway.createIdentity(
        const MailIdentity(id: '', emailAddress: 'ek@example.org'),
      );
      final id = await sourceMail();
      final prefill = await rig.gateway.getComposePrefill(id, 'reply-all');
      expect(prefill.to, ['yanit@example.org']);
    });

    test('a forward has no recipients and lists the attachments', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', turkishMail);
      final id = (await open('Inbox')).single;
      await rig.gateway.getMail(id, resolveFolder: _resolve);
      final prefill = await rig.gateway.getComposePrefill(id, 'forward');
      expect(prefill.to, isEmpty);
      expect(prefill.suggestedSubject, 'Fwd: Türkçe konu');
      expect(
        prefill.attachments.map((a) => a.name),
        contains('rapor şubat.pdf'),
      );
      expect(prefill.attachments.every((a) => a.id != null), isTrue);
    });

    test('prefixes are not doubled', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a', subject: 'RE: Zaten'));
      rig.imap.add('INBOX', rigMail('b', subject: 'Fw: Zaten'));
      final ids = await open('Inbox');
      expect(
        (await rig.gateway.getComposePrefill(ids[1], 'reply')).suggestedSubject,
        'RE: Zaten',
      );
      expect(
        (await rig.gateway.getComposePrefill(
          ids[1],
          'forward',
        )).suggestedSubject,
        'Fwd: RE: Zaten',
      );
      expect(
        (await rig.gateway.getComposePrefill(
          ids[0],
          'forward',
        )).suggestedSubject,
        'Fw: Zaten',
      );
    });

    test('an unknown kind is an argument error', () async {
      rig = DirectRig();
      final id = await sourceMail();
      await expectLater(
        rig.gateway.getComposePrefill(id, 'sideways'),
        throwsArgumentError,
      );
    });
  });

  test('signatures stay out of the gateway: the compose screen puts them in the body', () async {
    rig = DirectRig();
    final signature = await rig.gateway.createSignature(
      MailSignature(
        id: '',
        name: 'x',
        bodyText: 'Saygılar',
        createdAt: DateTime(2025),
        updatedAt: DateTime(2025),
      ),
    );
    await rig.gateway.sendMail(
      to: ['a@example.org'],
      subject: 's',
      bodyText: 'gövde',
      idempotencyKey: 'k1',
    );
    expect(signature.id, isNotEmpty);
    expect(MimeProcessor.processBody(received(0)).text.trim(), 'gövde');
  });
}
