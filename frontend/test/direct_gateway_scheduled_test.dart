import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/email.dart';
import 'package:kaydetmail/models/scheduled_send.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';

import 'support/direct_rig.dart';

Matcher _code(String code) =>
    isA<ApiException>().having((e) => e.code, 'code', code);

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  Future<ScheduledSend> schedule({
    String key = 'k1',
    Duration after = const Duration(hours: 1),
    List<Attachment> attachments = const [],
    List<String> to = const ['ali@example.org'],
  }) => rig.gateway.scheduleSend(
    to: to,
    subject: 'Zamanlı',
    bodyText: 'sonra',
    attachments: attachments,
    sendAtUtc: rig.clock.now.add(after),
    idempotencyKey: key,
  );

  test('a scheduled send waits, then goes out when its time comes', () async {
    rig = DirectRig();
    final item = await schedule();
    expect(item.status, ScheduledSendStatus.pending);
    expect(await rig.gateway.runDueScheduledSends(), 0);
    expect(rig.smtp.sent, isEmpty);

    rig.clock.advance(const Duration(hours: 1, minutes: 1));
    final events = <GatewayEventKind>[];
    rig.gateway.events.listen((e) => events.add(e.kind));
    expect(await rig.gateway.runDueScheduledSends(), 1);
    await Future<void>.delayed(Duration.zero);

    expect(rig.smtp.sent, hasLength(1));
    expect(rig.smtp.sent.single.envelopeRecipients, ['ali@example.org']);
    final list = await rig.gateway.listScheduledSends();
    expect(list.single.status, ScheduledSendStatus.sent);
    expect(events, contains(GatewayEventKind.scheduledSends));
    expect(await rig.gateway.runDueScheduledSends(), 0, reason: 'only once');
    expect(rig.smtp.sent, hasLength(1));
  });

  test('scheduling twice with the same key keeps one', () async {
    rig = DirectRig();
    final first = await schedule();
    final again = await schedule();
    expect(again.id, first.id);
    expect(await rig.gateway.listScheduledSends(), hasLength(1));
  });

  test('a time in the past is refused', () async {
    rig = DirectRig();
    await expectLater(
      schedule(after: const Duration(minutes: -1)),
      throwsA(_code('scheduled_send_in_past')),
    );
  });

  test('bad recipients are reported at scheduling time', () async {
    rig = DirectRig();
    await expectLater(
      schedule(to: ['nope']),
      throwsA(isA<DirectMailException>()),
    );
    expect(await rig.gateway.listScheduledSends(), isEmpty);
  });

  test('attachments are kept and go out with it', () async {
    rig = DirectRig();
    final bytes = Uint8List.fromList(List.generate(500, (i) => i % 200));
    final item = await schedule(
      attachments: [
        Attachment(name: 'ek.bin', sizeBytes: bytes.length, bytes: bytes),
      ],
    );
    final detail = await rig.gateway.getScheduledSend(item.id);
    expect(detail.attachments.single.name, 'ek.bin');
    expect(detail.attachments.single.sizeBytes, 500);
    rig.clock.advance(const Duration(hours: 2));
    await rig.gateway.runDueScheduledSends();
    expect(rig.smtp.sent.single.source, contains('ek.bin'));
    expect(
      rig.store.db
          .select('SELECT COUNT(*) AS n FROM d_scheduled_files')
          .first['n'],
      0,
      reason: 'the copy of the file is dropped once it is sent',
    );
  });

  group('changing a pending one', () {
    test('edit replaces the content and bumps the revision', () async {
      rig = DirectRig();
      final item = await schedule(
        attachments: [
          Attachment(name: 'a.txt', sizeBytes: 1, bytes: Uint8List(1)),
          Attachment(name: 'b.txt', sizeBytes: 1, bytes: Uint8List(1)),
        ],
      );
      final before = await rig.gateway.getScheduledSend(item.id);
      expect(before.revision, 1);
      final keep = before.attachments.first;
      await rig.gateway.updateScheduledSend(
        id: item.id,
        expectedRevision: 1,
        to: ['veli@example.org'],
        subject: 'Değişti',
        bodyText: 'yeni',
        sendAtUtc: rig.clock.now.add(const Duration(hours: 3)),
        keepAttachmentIds: [keep.id],
        attachments: [
          Attachment(name: 'c.txt', sizeBytes: 1, bytes: Uint8List(1)),
        ],
      );
      final after = await rig.gateway.getScheduledSend(item.id);
      expect(after.revision, 2);
      expect(after.subject, 'Değişti');
      expect(after.to, ['veli@example.org']);
      expect(after.attachments.map((a) => a.name), [keep.name, 'c.txt']);
    });

    test('a stale revision is a conflict', () async {
      rig = DirectRig();
      final item = await schedule();
      Future<void> edit(int revision) => rig.gateway.updateScheduledSend(
        id: item.id,
        expectedRevision: revision,
        to: ['a@example.org'],
        subject: 's',
        sendAtUtc: rig.clock.now.add(const Duration(hours: 2)),
      );
      await edit(1);
      await expectLater(edit(1), throwsA(_code('scheduled_send_modified')));
    });

    test('cancelling removes it from the list', () async {
      rig = DirectRig();
      final item = await schedule();
      await rig.gateway.cancelScheduledSend(item.id);
      expect(await rig.gateway.listScheduledSends(), isEmpty);
      rig.clock.advance(const Duration(hours: 2));
      expect(await rig.gateway.runDueScheduledSends(), 0);
      await rig.gateway.cancelScheduledSend(item.id); // idempotent
      await expectLater(
        rig.gateway.updateScheduledSend(
          id: item.id,
          expectedRevision: 1,
          to: ['a@example.org'],
          subject: 's',
          sendAtUtc: rig.clock.now.add(const Duration(hours: 5)),
        ),
        throwsA(_code('scheduled_send_not_pending')),
      );
    });

    test('a sent one can neither be cancelled nor edited', () async {
      rig = DirectRig();
      final item = await schedule();
      rig.clock.advance(const Duration(hours: 2));
      await rig.gateway.runDueScheduledSends();
      await expectLater(
        rig.gateway.cancelScheduledSend(item.id),
        throwsA(_code('scheduled_send_already_sent')),
      );
    });

    test('unknown ids are not found', () async {
      rig = DirectRig();
      await expectLater(
        rig.gateway.getScheduledSend('q:nope'),
        throwsA(_code('scheduled_send_not_found')),
      );
      await expectLater(
        rig.gateway.cancelScheduledSend('q:nope'),
        throwsA(_code('scheduled_send_not_found')),
      );
    });
  });

  group('when sending goes wrong', () {
    test('a temporary problem is retried later, with a growing wait', () async {
      rig = DirectRig();
      final item = await schedule();
      rig.clock.advance(const Duration(hours: 2));
      rig.smtp.failures.add(
        DirectMailException(DirectErrorKind.hostUnreachable),
      );
      await rig.gateway.runDueScheduledSends();
      var current = (await rig.gateway.listScheduledSends()).single;
      expect(current.status, ScheduledSendStatus.pending);
      expect(current.attemptCount, 1);
      expect(current.failureReason, 'host_unreachable');
      expect(current.nextAttemptAtUtc!.isAfter(rig.clock.now.toUtc()), isTrue);

      // Not yet.
      await rig.gateway.runDueScheduledSends();
      expect(rig.smtp.attempts, 1);

      rig.clock.advance(const Duration(minutes: 2));
      await rig.gateway.runDueScheduledSends();
      current = (await rig.gateway.listScheduledSends()).single;
      expect(current.status, ScheduledSendStatus.sent);
      expect(item.id, current.id);
    });

    test('a refusal is final', () async {
      rig = DirectRig();
      await schedule();
      rig.clock.advance(const Duration(hours: 2));
      rig.smtp.failures.add(
        DirectMailException(DirectErrorKind.smtpRecipientRejected),
      );
      await rig.gateway.runDueScheduledSends();
      final current = (await rig.gateway.listScheduledSends()).single;
      expect(current.status, ScheduledSendStatus.failed);
      expect(current.failureReason, 'smtp_recipient_rejected');
      rig.clock.advance(const Duration(hours: 5));
      await rig.gateway.runDueScheduledSends();
      expect(rig.smtp.attempts, 1, reason: 'a failed send is not retried');
    });

    test('an unknown outcome is never retried', () async {
      rig = DirectRig();
      await schedule();
      rig.clock.advance(const Duration(hours: 2));
      rig.smtp
        ..deliverThenFail = true
        ..failures.add(DirectMailException(DirectErrorKind.deliveryUncertain));
      await rig.gateway.runDueScheduledSends();
      final current = (await rig.gateway.listScheduledSends()).single;
      expect(current.status, ScheduledSendStatus.deliveryUnknown);
      rig.clock.advance(const Duration(days: 1));
      await rig.gateway.runDueScheduledSends();
      expect(rig.smtp.attempts, 1);
      expect(rig.smtp.sent, hasLength(1));
    });

    test('a failed one can be queued again as a new send', () async {
      rig = DirectRig();
      final item = await schedule(
        attachments: [
          Attachment(name: 'a.txt', sizeBytes: 1, bytes: Uint8List(1)),
        ],
      );
      rig.clock.advance(const Duration(hours: 2));
      rig.smtp.failures.add(DirectMailException(DirectErrorKind.smtpRejected));
      await rig.gateway.runDueScheduledSends();

      await rig.gateway.rescheduleFailedSend(
        id: item.id,
        to: ['baska@example.org'],
        subject: 'Yeniden',
        sendAtUtc: rig.clock.now.add(const Duration(minutes: 10)),
        idempotencyKey: 'again',
      );
      final list = await rig.gateway.listScheduledSends();
      expect(list, hasLength(1));
      expect(list.single.id, isNot(item.id));
      expect(list.single.status, ScheduledSendStatus.pending);
      expect(
        (await rig.gateway.getScheduledSend(list.single.id)).attachments,
        hasLength(1),
      );

      rig.clock.advance(const Duration(minutes: 11));
      await rig.gateway.runDueScheduledSends();
      expect(rig.smtp.sent.single.envelopeRecipients, ['baska@example.org']);

      // Asking again with the same key changes nothing.
      await rig.gateway.rescheduleFailedSend(
        id: item.id,
        to: ['x@example.org'],
        subject: 'x',
        sendAtUtc: rig.clock.now.add(const Duration(minutes: 10)),
        idempotencyKey: 'again',
      );
      expect(await rig.gateway.listScheduledSends(), hasLength(1));
    });

    test('only a failed send can be rescheduled', () async {
      rig = DirectRig();
      final item = await schedule();
      await expectLater(
        rig.gateway.rescheduleFailedSend(
          id: item.id,
          to: ['a@example.org'],
          subject: 's',
          sendAtUtc: rig.clock.now.add(const Duration(hours: 2)),
          idempotencyKey: 'k2',
        ),
        throwsA(_code('scheduled_send_not_pending')),
      );
    });
  });

  test(
    'a send that came due while the app was closed goes out at the next run',
    () async {
      rig = DirectRig();
      await schedule(after: const Duration(minutes: 5));
      rig.clock.advance(const Duration(days: 2));
      expect(await rig.gateway.runDueScheduledSends(), 1);
    },
  );

  test('two runs at once send it once', () async {
    rig = DirectRig();
    await schedule();
    rig.clock.advance(const Duration(hours: 2));
    final results = await Future.wait([
      rig.gateway.runDueScheduledSends(),
      rig.gateway.runDueScheduledSends(),
    ]);
    expect(results.reduce((a, b) => a + b), 1);
    expect(rig.smtp.sent, hasLength(1));
  });
}
