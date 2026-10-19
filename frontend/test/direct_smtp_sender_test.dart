import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/message_composer.dart';
import 'package:kaydetmail/services/direct/smtp_sender.dart';

import 'support/fake_smtp_server.dart';

ComposedMessage _message({List<String> to = const ['ali@example.org']}) =>
    MessageComposer.compose(
      ComposeInput(
        fromAddress: 'ben@example.com',
        to: to,
        bcc: const ['gizli@example.net'],
        subject: 'Merhaba',
        bodyText: 'Merhaba dünya\r\n.\r\nnokta ile başlayan satır',
      ),
    );

EnoughSmtpSender _sender(
  FakeSmtpServer server, {
  Duration sendTimeout = const Duration(seconds: 5),
}) => EnoughSmtpSender(
  endpoint: DirectEndpoint(
    host: '127.0.0.1',
    port: server.port,
    security: MailSecurity.startTls,
    username: 'ben@example.com',
  ),
  password: 'gizli',
  clientDomain: 'example.com',
  transport: SmtpTransport.plaintext,
  connectTimeout: const Duration(seconds: 5),
  sendTimeout: sendTimeout,
);

Matcher _kind(DirectErrorKind kind) =>
    isA<DirectMailException>().having((e) => e.kind, 'kind', kind);

void main() {
  late FakeSmtpServer server;
  tearDown(() => server.close());

  test('a message is submitted with its envelope and without Bcc', () async {
    server = await FakeSmtpServer.start();
    final progress = <int>[];
    final delivery = await _sender(server)
        .send(_message(), onProgress: (sent, total) => progress.add(sent));
    expect(delivery.serverReply, contains('queued'));
    expect(
      server.commands.where(
        (c) => c.startsWith('MAIL') || c.startsWith('RCPT'),
      ),
      [
        'MAIL FROM:<ben@example.com>',
        'RCPT TO:<ali@example.org>',
        'RCPT TO:<gizli@example.net>',
      ],
    );
    final received = server.messages.single;
    expect(received.toLowerCase(), isNot(contains('bcc:')));
    expect(received, contains('Subject: Merhaba'));
    expect(
      received,
      contains('\r\n..\r\n'),
      reason: 'a line made of a dot is escaped on the wire',
    );
    expect(progress.first, 0);
    expect(progress.last, greaterThan(0));
  });

  test('verify signs in and sends nothing', () async {
    server = await FakeSmtpServer.start(size: 5000000);
    final sender = _sender(server);
    await sender.verify();
    expect(server.messages, isEmpty);
    expect(server.commands.any((c) => c.startsWith('AUTH')), isTrue);
    expect(sender.maxMessageSize, 5000000);
  });

  group('refusals before the data is accepted are definite', () {
    test('a refused sign-in', () async {
      server = await FakeSmtpServer.start(
        authReply: '535 5.7.8 Authentication credentials invalid',
      );
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.authFailed)),
      );
      expect(server.messages, isEmpty);
    });

    test('a provider that wants an app password says so', () async {
      server = await FakeSmtpServer.start(
        authReply:
            '534-5.7.9 Application-specific password required.\r\n'
            '534 5.7.9 Learn more at the help page',
      );
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.authRequiresAppPassword)),
      );
    });

    test('a refused sender', () async {
      server = await FakeSmtpServer.start(
        mailReply: '553 5.7.1 Sender address rejected: not owned by user',
      );
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.smtpSenderRejected)),
      );
    });

    test('a refused recipient', () async {
      server = await FakeSmtpServer.start(rcptReply: '550 5.1.1 User unknown');
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.smtpRecipientRejected)),
      );
      expect(server.messages, isEmpty);
    });

    test('a temporary refusal asks to try later', () async {
      server = await FakeSmtpServer.start(
        rcptReply: '450 4.2.0 Greylisted, try again later',
      );
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.temporaryFailure)),
      );
    });

    test('a sending limit is told apart', () async {
      server = await FakeSmtpServer.start(
        mailReply: '550 5.4.5 Daily sending limit exceeded, too many messages',
      );
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.rateLimited)),
      );
    });

    test('a message over the announced size is not even offered', () async {
      server = await FakeSmtpServer.start(size: 100);
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.messageTooLarge)),
      );
      expect(server.commands.any((c) => c.startsWith('MAIL')), isFalse);
    });

    test('a connection lost before DATA is not a delivery question', () async {
      server = await FakeSmtpServer.start(dropBeforeData: true);
      await expectLater(
        _sender(server).send(_message()),
        throwsA(
          isA<DirectMailException>().having(
            (e) => e.kind,
            'kind',
            isNot(DirectErrorKind.deliveryUncertain),
          ),
        ),
      );
      expect(server.messages, isEmpty);
    });

    test(
      'a server that does not offer STARTTLS is never used in clear text',
      () async {
        server = await FakeSmtpServer.start(advertiseStartTls: false);
        final sender = EnoughSmtpSender(
          endpoint: DirectEndpoint(
            host: '127.0.0.1',
            port: server.port,
            security: MailSecurity.startTls,
            username: 'ben@example.com',
          ),
          password: 'gizli',
          clientDomain: 'example.com',
          transport: SmtpTransport.startTls,
          connectTimeout: const Duration(seconds: 5),
        );
        await expectLater(
          sender.send(_message()),
          throwsA(_kind(DirectErrorKind.tlsHandshakeFailed)),
        );
        expect(
          server.commands.any((c) => c.startsWith('AUTH')),
          isFalse,
          reason: 'the password never left',
        );
      },
    );
  });

  group('after the data was handed over', () {
    test('a refusal of the finished message is definite', () async {
      server = await FakeSmtpServer.start(
        finalReply: '554 5.7.1 Message rejected as spam',
      );
      await expectLater(
        _sender(server).send(_message()),
        throwsA(_kind(DirectErrorKind.smtpRejected)),
      );
    });

    test(
      'a temporary refusal of the finished message can be retried',
      () async {
        server = await FakeSmtpServer.start(
          finalReply: '451 4.3.0 Local error in processing',
        );
        await expectLater(
          _sender(server).send(_message()),
          throwsA(_kind(DirectErrorKind.temporaryFailure)),
        );
      },
    );

    test(
      'a connection lost with no answer is never reported as a plain failure',
      () async {
        server = await FakeSmtpServer.start(dropAfterData: true);
        await expectLater(
          _sender(server).send(_message()),
          throwsA(_kind(DirectErrorKind.deliveryUncertain)),
        );
        expect(
          server.messages,
          hasLength(1),
          reason: 'the server did receive it',
        );
      },
    );

    test('no answer in time is uncertain too', () async {
      server = await FakeSmtpServer.start(hangAfterData: true);
      await expectLater(
        _sender(
          server,
          sendTimeout: const Duration(milliseconds: 400),
        ).send(_message()),
        throwsA(_kind(DirectErrorKind.deliveryUncertain)),
      );
    });
  });

  group('cancelling', () {
    test('before the data starts means nothing was sent', () async {
      server = await FakeSmtpServer.start(rcptReply: '250 ok');
      final abort = Completer<void>()..complete();
      await expectLater(
        _sender(server).send(_message(), abort: abort.future),
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(server.messages, isEmpty);
    });
  });

  group('classifying server replies', () {
    DirectErrorKind kindOf(int code, String text, SmtpStage stage) =>
        EnoughSmtpSender.classifyReply(code, text, stage).kind;

    test(
      'a full mailbox at the recipient is a recipient problem, not a size one',
      () {
        expect(
          kindOf(552, '5.2.2 Mailbox full', SmtpStage.recipient),
          DirectErrorKind.smtpRecipientRejected,
        );
      },
    );

    test('too large is a size problem after DATA', () {
      expect(
        kindOf(
          552,
          '5.3.4 Message size exceeds fixed limit',
          SmtpStage.afterData,
        ),
        DirectErrorKind.messageTooLarge,
      );
    });

    test('421 means come back later', () {
      expect(
        kindOf(
          421,
          'Service not available, closing channel',
          SmtpStage.recipient,
        ),
        DirectErrorKind.temporaryFailure,
      );
    });

    test('anything unexplained after DATA is a rejection', () {
      expect(
        kindOf(550, 'Blocked by policy', SmtpStage.afterData),
        DirectErrorKind.smtpRejected,
      );
    });
  });
}
