import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';

import 'support/direct_rig.dart';

MailFolder _resolve(String id) => MailFolder.inbox;

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  Future<String> openInbox() async {
    final inbox = await rig.inboxId();
    await rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
    return inbox;
  }

  test(
    'a push brings the new mail in and describes it for a notification',
    () async {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('old'), date: rig.clock.now);
      final inbox = await openInbox();
      final events = <GatewayEvent>[];
      rig.gateway.events.listen(events.add);

      rig.gateway.setForeground(true);
      await _until(() => rig.imap.count('idle') > 0);

      rig.imap.add(
        'INBOX',
        rigMail(
          'new',
          subject: 'Acil toplantı',
          from: 'Şirin <sirin@example.org>',
          body: 'saat 10',
        ),
        date: rig.clock.now,
      );
      rig.imap.pushes.add(ImapPush.newMail);
      await _until(
        () => events.any(
          (e) => e.kind == GatewayEventKind.mail && e.incoming.isNotEmpty,
        ),
      );

      final event = events.firstWhere((e) => e.incoming.isNotEmpty);
      expect(event.folderId, inbox);
      final incoming = event.incoming.single;
      expect(incoming.subject, 'Acil toplantı');
      expect(incoming.sender, 'Şirin');
      expect(incoming.folderType, 'Inbox');
      final list = await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      );
      expect(list.items.first.subject, 'Acil toplantı');
    },
  );

  test('a first look at a folder is not news', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
    await rig.inboxId();
    final events = <GatewayEvent>[];
    rig.gateway.events.listen(events.add);
    rig.gateway.setForeground(true);
    await _until(() => events.any((e) => e.kind == GatewayEventKind.mail));
    expect(events.where((e) => e.incoming.isNotEmpty), isEmpty);
  });

  test('read, old and surplus mail is left out of the description', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('seed'), date: rig.clock.now);
    await openInbox();
    final events = <GatewayEvent>[];
    rig.gateway.events.listen(events.add);
    rig.gateway.setForeground(true);
    await _until(() => rig.imap.count('idle') > 0);

    rig.imap.add(
      'INBOX',
      rigMail('read'),
      flags: {r'\Seen'},
      date: rig.clock.now,
    );
    rig.imap.add(
      'INBOX',
      rigMail('old'),
      date: rig.clock.now.subtract(const Duration(days: 5)),
    );
    for (var i = 0; i < 8; i++) {
      rig.imap.add(
        'INBOX',
        rigMail('n$i', subject: 'Yeni $i'),
        date: rig.clock.now,
      );
    }
    rig.imap.pushes.add(ImapPush.newMail);
    await _until(() => events.any((e) => e.newMailIds.length == 10));
    final event = events.firstWhere((e) => e.newMailIds.length == 10);
    expect(event.incoming, hasLength(5), reason: 'a handful at most');
    expect(
      event.incoming.map((m) => m.subject).every((s) => s.startsWith('Yeni')),
      isTrue,
    );
  });

  test('a burst of pushes is one pass', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
    await openInbox();
    rig.gateway.setForeground(true);
    await _until(() => rig.imap.count('idle') > 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    rig.imap.resetCalls();
    rig.imap.add('INBOX', rigMail('b'), date: rig.clock.now);
    for (var i = 0; i < 5; i++) {
      rig.imap.pushes.add(ImapPush.newMail);
    }
    await _until(() => rig.imap.count('select') > 0);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(rig.imap.count('select'), lessThanOrEqualTo(2));
  });

  test('a push that arrives during a pass is not lost', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
    final inbox = await openInbox();
    final events = <GatewayEvent>[];
    rig.gateway.events.listen(events.add);
    rig.gateway.setForeground(true);
    await _until(() => rig.imap.count('idle') > 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    rig.imap.add('INBOX', rigMail('b'), date: rig.clock.now);
    rig.imap.pushes.add(ImapPush.newMail);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    rig.imap.add('INBOX', rigMail('c'), date: rig.clock.now);
    rig.imap.pushes.add(ImapPush.newMail);
    await _until(() => events.expand((e) => e.newMailIds).length >= 2);
    final list = await rig.gateway.getMails(
      folderId: inbox,
      resolveFolder: _resolve,
    );
    expect(list.items, hasLength(3));
  });

  test('in the background nothing is watched', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
    await openInbox();
    rig.gateway.setForeground(true);
    await _until(() => rig.imap.count('idle') > 0);
    rig.gateway.setForeground(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final events = <GatewayEvent>[];
    rig.gateway.events.listen(events.add);
    rig.imap.add('INBOX', rigMail('b'), date: rig.clock.now);
    rig.imap.pushes.add(ImapPush.newMail);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(events.where((e) => e.kind == GatewayEventKind.mail), isEmpty);
  });

  test('a server without IDLE is asked on a timer', () {
    fakeAsync((async) {
      rig = DirectRig(capabilities: {'IMAP4REV1', 'NAMESPACE'});
      rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
      late String inbox;
      rig.inboxId().then((id) => inbox = id);
      async.flushMicrotasks();
      rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
      async.flushMicrotasks();
      final events = <GatewayEvent>[];
      rig.gateway.events.listen(events.add);

      rig.gateway.setForeground(true);
      async.flushMicrotasks();
      expect(rig.imap.count('idle'), 0);

      rig.imap.add('INBOX', rigMail('b'), date: rig.clock.now);
      rig.clock.advance(const Duration(minutes: 2));
      async.elapse(const Duration(seconds: 91));
      async.flushMicrotasks();
      expect(
        events.where(
          (e) => e.kind == GatewayEventKind.mail && e.newMailIds.isNotEmpty,
        ),
        isNotEmpty,
      );
      rig.gateway.setForeground(false);
      async.flushMicrotasks();
    });
  });

  test('a broken watch starts again after a while', () {
    fakeAsync((async) {
      rig = DirectRig();
      rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
      late String inbox;
      rig.inboxId().then((id) => inbox = id);
      async.flushMicrotasks();
      rig.gateway.getMails(folderId: inbox, resolveFolder: _resolve);
      async.flushMicrotasks();

      rig.gateway.setForeground(true);
      async.flushMicrotasks();
      expect(rig.imap.count('idle'), 1);

      rig.imap.pushes.addError(
        DirectMailException(DirectErrorKind.hostUnreachable),
      );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(rig.imap.count('idle'), greaterThanOrEqualTo(2));
      rig.gateway.setForeground(false);
      async.flushMicrotasks();
    });
  });

  test('coming to the front sends what has come due', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('a'), date: rig.clock.now);
    await rig.inboxId();
    await rig.gateway.scheduleSend(
      to: ['x@example.org'],
      subject: 's',
      sendAtUtc: rig.clock.now.add(const Duration(minutes: 5)),
      idempotencyKey: 'k1',
    );
    rig.clock.advance(const Duration(minutes: 10));
    rig.gateway.setForeground(true);
    await _until(() => rig.smtp.sent.isNotEmpty);
  });
}
