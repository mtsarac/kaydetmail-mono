import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/mail_folder.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/direct_store.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';
import 'package:kaydetmail/services/direct/sync_engine.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';

import 'support/direct_rig.dart';

MailFolder _resolve(String id) => MailFolder.inbox;

String _mail(
  String id, {
  String subject = 'Konu',
  String from = 'ayse@example.org',
  String body = 'metin',
}) => [
  'From: $from',
  'To: $rigAddress',
  'Subject: =?UTF-8?B?${base64.encode(utf8.encode(subject))}?=',
  'Message-ID: <$id@example.org>',
  'Date: Mon, 6 Oct 2025 10:00:00 +0000',
  'MIME-Version: 1.0',
  'Content-Type: text/plain; charset=utf-8',
  '',
  body,
  '',
].join('\r\n');

void main() {
  late DirectRig rig;
  tearDown(() async {
    try {
      await rig.dispose();
    } on Error {
      // A test that never built one (a plain function test).
    }
  });

  /// Opens the Inbox and reads only its first message, so the device holds
  /// the first sync's window and nothing more.
  Future<void> load() async {
    final inbox = await rig.inboxId();
    await rig.gateway.getMails(
      folderId: inbox,
      resolveFolder: _resolve,
      pageSize: 1,
    );
  }

  group('folding Turkish text', () {
    test('İ, I, ı and i are one letter; accents do not matter', () {
      expect(DirectStore.foldForSearch('İSTANBUL ışık'), 'istanbul isik');
      expect(
        DirectStore.foldForSearch('Şirket ÇAĞRI Öğüt'),
        'sirket cagri ogut',
      );
      expect(DirectStore.foldForSearch('Café'), 'cafe');
    });
  });

  group('on the device', () {
    test('finds mail typed with an English keyboard', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', _mail('a', subject: 'Şirket toplantısı'));
      rig.imap.add('INBOX', _mail('b', subject: 'Fatura'));
      await load();
      final page = await rig.gateway.search(
        query: 'sirket toplantisi',
        resolveFolder: _resolve,
      );
      expect(page.items.map((e) => e.subject), ['Şirket toplantısı']);
      expect(page.total, 1);
      final upper = await rig.gateway.search(
        query: 'İSTANBUL',
        resolveFolder: _resolve,
      );
      expect(upper.items, isEmpty);
    });

    test('every word has to match, in any field', () async {
      rig = DirectRig();
      rig.imap.add(
        'INBOX',
        _mail('a', subject: 'Plan', from: 'Ali Veli <ali@example.org>'),
      );
      rig.imap.add(
        'INBOX',
        _mail('b', subject: 'Plan', from: 'Can <can@example.org>'),
      );
      await load();
      final both = await rig.gateway.search(
        query: 'plan veli',
        resolveFolder: _resolve,
      );
      expect(both.items, hasLength(1));
      expect(
        (await rig.gateway.search(
          query: 'plan',
          resolveFolder: _resolve,
        )).items,
        hasLength(2),
      );
    });

    test('looks inside bodies that are stored', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', _mail('a', body: 'gizli kelime burada'));
      await load();
      final id = (await rig.gateway.search(
        query: '',
        resolveFolder: _resolve,
      )).items.single.id;
      expect(
        (await rig.gateway.search(
          query: 'gizli kelime',
          resolveFolder: _resolve,
        )).items,
        isEmpty,
      );
      await rig.gateway.getMail(id, resolveFolder: _resolve);
      expect(
        (await rig.gateway.search(
          query: 'gizli kelime',
          resolveFolder: _resolve,
        )).items,
        hasLength(1),
      );
    });

    test(
      'filters narrow by sender, state, attachment, label, folder and thread',
      () async {
        rig = DirectRig();
        rig.imap.addFolder('Projeler');
        rig.imap.add(
          'INBOX',
          _mail('a', subject: 'Bir', from: 'ali@example.org'),
          flags: {r'\Seen', r'\Flagged'},
        );
        rig.imap.add(
          'INBOX',
          _mail('b', subject: 'İki', from: 'can@example.org'),
        );
        rig.imap.add(
          'Projeler',
          _mail('c', subject: 'Üç', from: 'ali@example.org'),
        );
        await load();
        final folders = await rig.gateway.getFolders();
        final projects = folders.firstWhere((f) => f.fullName == 'Projeler');
        await rig.gateway.getMails(
          folderId: projects.id,
          resolveFolder: _resolve,
        );

        Future<List<String>> subjects(Future<MailListPage> page) async => [
          for (final e in (await page).items) e.subject,
        ];

        expect(
          await subjects(
            rig.gateway.search(query: '', resolveFolder: _resolve, from: 'ali'),
          ),
          unorderedEquals(['Bir', 'Üç']),
        );
        expect(
          await subjects(
            rig.gateway.search(
              query: '',
              resolveFolder: _resolve,
              isRead: false,
            ),
          ),
          unorderedEquals(['İki', 'Üç']),
        );
        expect(
          await subjects(
            rig.gateway.search(
              query: '',
              resolveFolder: _resolve,
              flagged: true,
            ),
          ),
          ['Bir'],
        );
        expect(
          await subjects(
            rig.gateway.search(
              query: '',
              resolveFolder: _resolve,
              folderId: projects.id,
            ),
          ),
          ['Üç'],
        );
        expect(
          await subjects(
            rig.gateway.search(
              query: '',
              resolveFolder: _resolve,
              hasAttachment: true,
            ),
          ),
          isEmpty,
        );

        final ids = [
          for (final e in (await rig.gateway.search(
            query: 'iki',
            resolveFolder: _resolve,
          )).items)
            e.id,
        ];
        final label = await rig.gateway.createLabel('Önemli', 1);
        await rig.gateway.assignLabels(ids, [label['id'] as String]);
        expect(
          await subjects(
            rig.gateway.search(
              query: '',
              resolveFolder: _resolve,
              labelId: label['id'] as String,
            ),
          ),
          ['İki'],
        );

        final thread = (await rig.gateway.search(
          query: 'iki',
          resolveFolder: _resolve,
        )).items.single.threadId;
        expect(
          await subjects(
            rig.gateway.search(
              query: '',
              resolveFolder: _resolve,
              conversationId: thread,
            ),
          ),
          ['İki'],
        );
      },
    );

    test('dates bound the result', () async {
      rig = DirectRig();
      rig.imap.add(
        'INBOX',
        _mail('a', subject: 'Eski'),
        date: DateTime.utc(2024, 1, 5),
      );
      rig.imap.add(
        'INBOX',
        _mail('b', subject: 'Yeni'),
        date: DateTime.utc(2025, 6, 5),
      );
      await load();
      final page = await rig.gateway.search(
        query: '',
        resolveFolder: _resolve,
        fromDate: DateTime.utc(2025),
        toDate: DateTime.utc(2026),
      );
      expect(page.items.map((e) => e.subject), ['Yeni']);
    });

    test('Trash and Spam are left out unless searched directly', () async {
      rig = DirectRig();
      rig.imap.addFolder('Trash', use: FolderRole.trash);
      rig.imap.add('INBOX', _mail('a', subject: 'Ortak konu'));
      rig.imap.add('Trash', _mail('b', subject: 'Ortak konu çöpte'));
      await load();
      final trash = (await rig.gateway.getFolders()).firstWhere(
        (f) => f.type == 'Trash',
      );
      await rig.gateway.getMails(folderId: trash.id, resolveFolder: _resolve);
      expect(
        (await rig.gateway.search(
          query: 'ortak',
          resolveFolder: _resolve,
        )).items,
        hasLength(1),
      );
      expect(
        (await rig.gateway.search(
          query: 'ortak',
          resolveFolder: _resolve,
          folderId: trash.id,
        )).items,
        hasLength(1),
      );
    });

    test('pages through the matches', () async {
      rig = DirectRig();
      for (var i = 0; i < 7; i++) {
        rig.imap.add('INBOX', _mail('m$i', subject: 'Toplu $i'));
      }
      await load();
      final first = await rig.gateway.search(
        query: 'toplu',
        resolveFolder: _resolve,
        pageSize: 3,
      );
      final last = await rig.gateway.search(
        query: 'toplu',
        resolveFolder: _resolve,
        pageSize: 3,
        page: 3,
      );
      expect(first.total, 7);
      expect(first.items, hasLength(3));
      expect(last.items, hasLength(1));
    });

    test(
      'the folder search in the list also ignores case and accents',
      () async {
        rig = DirectRig();
        rig.imap.add('INBOX', _mail('a', subject: 'Çalışma planı'));
        final inbox = await rig.inboxId();
        final page = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
          search: 'CALISMA',
        );
        expect(page.items, hasLength(1));
      },
    );
  });

  group('on the server', () {
    test('brings in what the device has not got and counts the rest', () async {
      rig = DirectRig(
        options: const SyncOptions(initialWindow: 5, prefetchBodies: 0),
      );
      for (var i = 1; i <= 20; i++) {
        rig.imap.add(
          'INBOX',
          _mail(
            'm$i',
            subject: 'Konu $i',
            body: i == 2 || i == 3 ? 'nadir kelime' : 'sıradan',
          ),
        );
      }
      await load(); // newest 5 only
      expect(
        (await rig.gateway.search(
          query: 'nadir',
          resolveFolder: _resolve,
        )).items,
        isEmpty,
      );

      final result = await rig.gateway.searchRemote(query: 'nadir');
      expect(result.matched, 2);
      expect(result.imported, 2);
      expect(result.complete, isTrue);
      expect(
        (await rig.gateway.search(
          query: 'nadir',
          resolveFolder: _resolve,
        )).items,
        hasLength(2),
      );

      // Asking again finds them already here.
      final again = await rig.gateway.searchRemote(query: 'nadir');
      expect(again.matched, 2);
      expect(again.imported, 0);
    });

    test('a hit the device holds without its text gets the text', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', _mail('a', body: 'gizlikelime'));
      await load();
      expect(
        (await rig.gateway.search(
          query: 'gizlikelime',
          resolveFolder: _resolve,
        )).items,
        isEmpty,
      );
      final result = await rig.gateway.searchRemote(query: 'gizlikelime');
      expect(result.matched, 1);
      expect(result.imported, 0, reason: 'the message itself was already here');
      expect(result.complete, isTrue);
      expect(
        (await rig.gateway.search(
          query: 'gizlikelime',
          resolveFolder: _resolve,
        )).items,
        hasLength(1),
      );
    });

    test(
      'takes a limited number at a time and says how many are left',
      () async {
        rig = DirectRig(
          options: const SyncOptions(initialWindow: 2, prefetchBodies: 0),
        );
        for (var i = 1; i <= 130; i++) {
          rig.imap.add('INBOX', _mail('m$i', body: 'ortak'));
        }
        await load();
        final first = await rig.gateway.searchRemote(query: 'ortak');
        expect(first.matched, 130);
        expect(
          first.imported,
          38,
          reason: '40 messages worked on, 2 were here',
        );
        expect(
          first.remaining,
          90,
          reason: '130 matched, none with its text yet, 40 taken',
        );
        expect(first.complete, isFalse);
        var rounds = 1;
        var last = first;
        while (!last.complete && rounds < 10) {
          last = await rig.gateway.searchRemote(query: 'ortak');
          rounds++;
        }
        expect(last.complete, isTrue);
        expect(rounds, 4, reason: '40 + 40 + 40 + the last 10');
      },
    );

    test('imports do not make older mail unreachable by scrolling', () async {
      rig = DirectRig(
        options: const SyncOptions(initialWindow: 5, prefetchBodies: 0),
      );
      for (var i = 1; i <= 25; i++) {
        rig.imap.add(
          'INBOX',
          _mail('m$i', subject: 'Konu $i', body: i == 2 ? 'igne' : 'saman'),
        );
      }
      await load();
      await rig.gateway.searchRemote(query: 'igne');
      final inbox = await rig.inboxId();
      final all = <String>{};
      for (var page = 1; page <= 8; page++) {
        final result = await rig.gateway.getMails(
          folderId: inbox,
          resolveFolder: _resolve,
          page: page,
          pageSize: 5,
        );
        all.addAll(result.items.map((e) => e.subject));
      }
      expect(all, hasLength(25));
    });

    test('a search with non-ASCII letters stays on the device', () async {
      rig = DirectRig();
      rig.imap.add('INBOX', _mail('a'));
      await load();
      // The real IMAP client refuses non-ASCII criteria; the double mirrors
      // that by raising the same error.
      rig.imap.failNext(
        'search',
        DirectMailException(DirectErrorKind.capabilityMissing),
      );
      await expectLater(
        rig.gateway.searchRemote(query: 'şirket'),
        throwsA(
          isA<DirectMailException>().having(
            (e) => e.code,
            'code',
            'capability_missing',
          ),
        ),
      );
    });

    test('searches the chosen folder only', () async {
      rig = DirectRig();
      rig.imap.addFolder('Projeler');
      rig.imap.add('INBOX', _mail('a', body: 'aranan'));
      rig.imap.add('Projeler', _mail('b', body: 'aranan'));
      await load();
      final projects = (await rig.gateway.getFolders()).firstWhere(
        (f) => f.fullName == 'Projeler',
      );
      final result = await rig.gateway.searchRemote(
        query: 'aranan',
        folderId: projects.id,
      );
      expect(result.matched, 1);
      expect(result.imported, 1);
    });
  });
}
