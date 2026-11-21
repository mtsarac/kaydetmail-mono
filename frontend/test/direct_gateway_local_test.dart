import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/models/mail_signature.dart';
import 'package:kaydetmail/models/mail_template.dart';
import 'package:kaydetmail/models/trusted_sender.dart';
import 'package:kaydetmail/services/api_exception.dart';

import 'support/direct_rig.dart';

MailFolder _resolve(String id) => MailFolder.inbox;

Matcher _code(String code) =>
    isA<ApiException>().having((e) => e.code, 'code', code);

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  Future<List<String>> inboxMail(int count) async {
    for (var i = 0; i < count; i++) {
      rig.imap.add('INBOX', rigMail('m$i', subject: 'Konu $i'));
    }
    final inbox = await rig.inboxId();
    final page = await rig.gateway.getMails(
      folderId: inbox,
      resolveFolder: _resolve,
    );
    return [for (final e in page.items) e.id];
  }

  group('pins', () {
    test('at most three, and unpinning frees a place', () async {
      rig = DirectRig();
      final ids = await inboxMail(5);
      final results = await rig.gateway.setPinned(ids, true);
      expect(results.where((r) => r.success), hasLength(3));
      final refused = results.where((r) => !r.success).toList();
      expect(refused.map((r) => r.code), everyElement('pinned_limit_reached'));
      expect((await rig.gateway.getPinnedMailIds()), hasLength(3));

      await rig.gateway.setPinned([ids.first], false);
      final again = await rig.gateway.setPinned([refused.first.mailId], true);
      expect(again.single.success, isTrue);
    });

    test('pinning twice is fine and unknown mail is refused', () async {
      rig = DirectRig();
      final ids = await inboxMail(1);
      await rig.gateway.setPinned(ids, true);
      expect((await rig.gateway.setPinned(ids, true)).single.success, isTrue);
      final unknown = await rig.gateway.setPinned(['d:nope'], true);
      expect(unknown.single.code, 'mail_not_found');
    });

    test('a pin follows the mail into another folder', () async {
      rig = DirectRig();
      rig.imap.addFolder('Projeler');
      final ids = await inboxMail(1);
      await rig.gateway.setPinned(ids, true);
      final projects = (await rig.gateway.getFolders()).firstWhere(
        (f) => f.fullName == 'Projeler',
      );
      await rig.gateway.moveMail(ids.single, projects.id);
      expect(await rig.gateway.getPinnedMailIds(), ids);
    });

    test('a pin goes when the mail is deleted', () async {
      rig = DirectRig();
      final ids = await inboxMail(1);
      await rig.gateway.setPinned(ids, true);
      await rig.gateway.bulkAction('delete', ids);
      expect(await rig.gateway.getPinnedMailIds(), isEmpty);
    });
  });

  group('snoozes', () {
    test('are kept until their time, then dropped', () async {
      rig = DirectRig();
      final ids = await inboxMail(2);
      final soon = rig.clock.now.add(const Duration(hours: 1));
      await rig.gateway.setSnooze(ids[0], soon);
      await rig.gateway.setSnooze(
        ids[1],
        rig.clock.now.add(const Duration(days: 1)),
      );
      expect((await rig.gateway.getSnoozed()).keys, unorderedEquals(ids));
      rig.clock.advance(const Duration(hours: 2));
      expect((await rig.gateway.getSnoozed()).keys, [ids[1]]);
      await rig.gateway.clearSnooze(ids[1]);
      await rig.gateway.clearSnooze(ids[1]); // idempotent
      expect(await rig.gateway.getSnoozed(), isEmpty);
    });

    test('unknown mail cannot be snoozed', () async {
      rig = DirectRig();
      await expectLater(
        rig.gateway.setSnooze(
          'd:nope',
          rig.clock.now.add(const Duration(hours: 1)),
        ),
        throwsA(_code('mail_not_found')),
      );
    });

    test('re-snoozing replaces the deadline', () async {
      rig = DirectRig();
      final ids = await inboxMail(1);
      await rig.gateway.setSnooze(
        ids.single,
        rig.clock.now.add(const Duration(hours: 1)),
      );
      final later = rig.clock.now.add(const Duration(days: 2));
      await rig.gateway.setSnooze(ids.single, later);
      expect((await rig.gateway.getSnoozed())[ids.single], later);
    });
  });

  group('labels', () {
    test(
      'names are unique ignoring case; assignments survive and clean up',
      () async {
        rig = DirectRig();
        final ids = await inboxMail(2);
        final work = await rig.gateway.createLabel('İş', -1234);
        await expectLater(
          rig.gateway.createLabel('iş', 5),
          throwsA(_code('label_name_taken')),
        );
        final home = await rig.gateway.createLabel('Ev', 7);
        expect((await rig.gateway.getLabels()).map((l) => l['name']), [
          'İş',
          'Ev',
        ]);

        await rig.gateway.assignLabels(ids, [work['id'] as String]);
        await rig.gateway.assignLabels(
          [ids[0]],
          [home['id'] as String, work['id'] as String],
        );
        final map = await rig.gateway.getLabelAssignments();
        expect(map[ids[0]], containsAll([work['id'], home['id']]));
        expect(map[ids[1]], [work['id']]);

        await rig.gateway.unassignLabels([ids[0]], [work['id'] as String]);
        expect((await rig.gateway.getLabelAssignments())[ids[0]], [home['id']]);

        await rig.gateway.updateLabel(home['id'] as String, 'Aile', 9);
        expect((await rig.gateway.getLabels()).last['name'], 'Aile');
        await expectLater(
          rig.gateway.updateLabel(home['id'] as String, 'İş', 9),
          throwsA(_code('label_name_taken')),
        );

        await rig.gateway.deleteLabel(work['id'] as String);
        final after = await rig.gateway.getLabelAssignments();
        expect(after.values.expand((l) => l), isNot(contains(work['id'])));
      },
    );

    test('assigning an unknown label fails, unknown mail is skipped', () async {
      rig = DirectRig();
      final ids = await inboxMail(1);
      await expectLater(
        rig.gateway.assignLabels(ids, ['l:nope']),
        throwsA(_code('label_not_found')),
      );
      final label = await rig.gateway.createLabel('A', 1);
      await rig.gateway.assignLabels(
        ['d:nope', ...ids],
        [label['id'] as String],
      );
      expect((await rig.gateway.getLabelAssignments()).keys, ids);
    });

    test('labels stay on a mail that is moved', () async {
      rig = DirectRig();
      rig.imap.addFolder('Arşivim');
      final ids = await inboxMail(1);
      final label = await rig.gateway.createLabel('Önemli', 3);
      await rig.gateway.assignLabels(ids, [label['id'] as String]);
      final target = (await rig.gateway.getFolders()).firstWhere(
        (f) => f.fullName == 'Arşivim',
      );
      await rig.gateway.moveMail(ids.single, target.id);
      expect((await rig.gateway.getLabelAssignments())[ids.single], [
        label['id'],
      ]);
    });
  });

  group('contacts', () {
    test('validate, stay unique and can be edited', () async {
      rig = DirectRig();
      final ali = await rig.gateway.createContact('ali@example.org', 'Ali');
      await expectLater(
        rig.gateway.createContact('ALI@example.org', null),
        throwsA(_code('contact_already_exists')),
      );
      await expectLater(
        rig.gateway.createContact('not an address', null),
        throwsA(_code('invalid_email')),
      );
      final updated = await rig.gateway.updateContact(
        ali['id'] as String,
        'ali@example.com',
        '  ',
      );
      expect(updated['displayName'], isNull);
      expect(
        (await rig.gateway.getContacts()).single['email'],
        'ali@example.com',
      );
      await rig.gateway.deleteContact(ali['id'] as String);
      expect(await rig.gateway.getContacts(), isEmpty);
      await expectLater(
        rig.gateway.updateContact('c:nope', 'a@b.co', null),
        throwsA(_code('contact_not_found')),
      );
    });
  });

  group('templates', () {
    MailTemplate draft(String name) => MailTemplate(
      id: '',
      name: name,
      subject: 'Konu',
      bodyText: 'Metin',
      createdAt: DateTime(2025),
      updatedAt: DateTime(2025),
    );

    test('are created, renamed and removed; names are unique', () async {
      rig = DirectRig();
      final created = await rig.gateway.createTemplate(draft('Teşekkür'));
      expect(created.id, isNotEmpty);
      await expectLater(
        rig.gateway.createTemplate(draft('teşekkür')),
        throwsA(_code('template_name_taken')),
      );
      final other = await rig.gateway.createTemplate(draft('Randevu'));
      await expectLater(
        rig.gateway.updateTemplate(other.copyWith(name: 'TEŞEKKÜR')),
        throwsA(_code('template_name_taken')),
      );
      final renamed = await rig.gateway.updateTemplate(
        other.copyWith(name: 'Toplantı', bodyText: 'Yeni'),
      );
      expect(renamed.bodyText, 'Yeni');
      expect((await rig.gateway.getTemplates()).map((t) => t.name), [
        'Teşekkür',
        'Toplantı',
      ]);
      await rig.gateway.deleteTemplate(created.id);
      expect(await rig.gateway.getTemplates(), hasLength(1));
      await expectLater(
        rig.gateway.updateTemplate(created),
        throwsA(_code('template_not_found')),
      );
    });
  });

  group('signatures and identities', () {
    MailSignature sig(String name) => MailSignature(
      id: '',
      name: name,
      bodyText: 'Saygılar',
      createdAt: DateTime(2025),
      updatedAt: DateTime(2025),
    );

    test(
      'defaults must exist and are forgotten when a signature goes',
      () async {
        rig = DirectRig();
        final a = await rig.gateway.createSignature(sig('Resmi'));
        final b = await rig.gateway.createSignature(sig('Samimi'));
        await expectLater(
          rig.gateway.updateSignatureDefaults(
            const SignatureDefaults(newMailSignatureId: 's:nope'),
          ),
          throwsA(_code('signature_not_found')),
        );
        await rig.gateway.updateSignatureDefaults(
          SignatureDefaults(newMailSignatureId: a.id, replySignatureId: b.id),
        );
        await rig.gateway.deleteSignature(a.id);
        final loaded = await rig.gateway.getSignatures();
        expect(loaded.items.map((s) => s.name), ['Samimi']);
        expect(loaded.defaults.newMailSignatureId, isNull);
        expect(loaded.defaults.replySignatureId, b.id);
      },
    );

    test(
      'an identity can name a signature; deleting the signature clears it',
      () async {
        rig = DirectRig();
        final s = await rig.gateway.createSignature(sig('Resmi'));
        final first = await rig.gateway.createIdentity(
          MailIdentity(
            id: '',
            emailAddress: 'ben@example.com',
            displayName: 'Ben',
            signatureId: s.id,
            isDefault: true,
          ),
        );
        expect(first.isDefault, isTrue);
        final second = await rig.gateway.createIdentity(
          const MailIdentity(
            id: '',
            emailAddress: 'info@example.com',
            isDefault: true,
          ),
        );
        final list = await rig.gateway.getIdentities();
        expect(list.where((i) => i.isDefault).map((i) => i.id), [second.id]);
        await expectLater(
          rig.gateway.createIdentity(
            const MailIdentity(id: '', emailAddress: 'INFO@example.com'),
          ),
          throwsA(_code('identity_already_exists')),
        );
        await expectLater(
          rig.gateway.createIdentity(
            const MailIdentity(
              id: '',
              emailAddress: 'x@example.com',
              signatureId: 's:nope',
            ),
          ),
          throwsA(_code('signature_not_found')),
        );
        await rig.gateway.deleteSignature(s.id);
        expect(
          (await rig.gateway.getIdentities())
              .firstWhere((i) => i.id == first.id)
              .signatureId,
          isNull,
        );
        await rig.gateway.deleteIdentity(second.id);
        expect(await rig.gateway.getIdentities(), hasLength(1));
        await expectLater(
          rig.gateway.updateIdentity(second),
          throwsA(_code('identity_not_found')),
        );
      },
    );
  });

  group('trusted senders', () {
    test('a trusted sender or domain has its images allowed', () async {
      rig = DirectRig();
      rig.imap.add(
        'INBOX',
        [
          'From: Haber <haber@news.example>',
          'To: $rigAddress',
          'Subject: Bülten',
          'Message-ID: <b@news.example>',
          'Date: Mon, 6 Oct 2025 10:00:00 +0000',
          'MIME-Version: 1.0',
          'Content-Type: text/html; charset=utf-8',
          '',
          '<img src="https://images.news.example/a.png" width="400">',
          '',
        ].join('\r\n'),
      );
      final inbox = await rig.inboxId();
      final id = (await rig.gateway.getMails(
        folderId: inbox,
        resolveFolder: _resolve,
      )).items.single.id;

      expect(
        (await rig.gateway.getMail(
          id,
          resolveFolder: _resolve,
        )).remoteImagesAllowed,
        isFalse,
      );
      final trusted = await rig.gateway.addTrustedSender(
        TrustedSenderKind.domain,
        'News.Example',
      );
      expect(trusted.value, 'news.example');
      final again = await rig.gateway.addTrustedSender(
        TrustedSenderKind.domain,
        'news.example',
      );
      expect(again.id, trusted.id, reason: 'adding twice keeps one');
      final opened = await rig.gateway.getMail(id, resolveFolder: _resolve);
      expect(opened.remoteImagesAllowed, isTrue);
      expect(
        opened.bodyHtml,
        contains('src="https://images.news.example/a.png"'),
      );

      await rig.gateway.removeTrustedSender(trusted.id);
      expect(
        (await rig.gateway.getMail(
          id,
          resolveFolder: _resolve,
        )).remoteImagesAllowed,
        isFalse,
      );
      await rig.gateway.addTrustedSender(
        TrustedSenderKind.sender,
        'haber@news.example',
      );
      expect(
        (await rig.gateway.getMail(
          id,
          resolveFolder: _resolve,
        )).remoteImagesAllowed,
        isTrue,
      );
    });

    test('rejects malformed entries', () async {
      rig = DirectRig();
      await expectLater(
        rig.gateway.addTrustedSender(TrustedSenderKind.sender, 'no-at'),
        throwsA(_code('invalid_request')),
      );
      await expectLater(
        rig.gateway.addTrustedSender(TrustedSenderKind.domain, 'a@b.co'),
        throwsA(_code('invalid_request')),
      );
    });
  });

  test('deleting the account takes every local feature with it', () async {
    rig = DirectRig();
    final ids = await inboxMail(1);
    await rig.gateway.setPinned(ids, true);
    await rig.gateway.createLabel('A', 1);
    await rig.gateway.createContact('a@b.co', null);
    await rig.gateway.createSignature(
      MailSignature(
        id: '',
        name: 'x',
        bodyText: 'y',
        createdAt: DateTime(2025),
        updatedAt: DateTime(2025),
      ),
    );
    await rig.gateway.deleteAccount();
    for (final table in [
      'd_pins',
      'd_labels',
      'd_contacts',
      'd_signatures',
      'd_messages',
      'd_folders',
      'd_settings',
    ]) {
      final n = rig.store.db
          .select('SELECT COUNT(*) AS n FROM $table')
          .first['n'];
      expect(n, 0, reason: table);
    }
  });
}
