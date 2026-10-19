import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_exception.dart';
import 'package:kaydetmail/services/direct/connection_policy.dart';
import 'package:kaydetmail/services/direct/direct_connection.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/imap_models.dart';

import 'support/fake_imap_service.dart';

class _Rig {
  _Rig({
    this.online = true,
    Duration idleClose = const Duration(minutes: 5),
    Set<String>? capabilities,
  }) {
    policy = ConnectionPolicy(
      clock: () => now,
      random: _FixedRandom(),
      schedule: const [
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
      ],
    );
    connection = DirectConnection(
      create: () {
        final imap = capabilities == null
            ? FakeImapService()
            : FakeImapService(capabilities: capabilities);
        imap.addFolder('INBOX', use: FolderRole.inbox);
        if (connectErrors.isNotEmpty) {
          imap.failNext('connect', connectErrors.removeAt(0));
        }
        created.add(imap);
        return imap;
      },
      policy: policy,
      isOnline: () async => online,
      idleClose: idleClose,
      onNeedsReauthentication: () => reauthCalls++,
      onRecovered: () => recoveredCalls++,
    );
  }

  DateTime now = DateTime.utc(2026, 1, 1, 12);
  bool online;
  final List<FakeImapService> created = [];
  final List<Object> connectErrors = [];
  int reauthCalls = 0;
  int recoveredCalls = 0;
  late final ConnectionPolicy policy;
  late final DirectConnection connection;

  void advance(Duration d) => now = now.add(d);

  Future<void> ping({bool userInitiated = false}) =>
      connection.run<void>((imap) async {
        await imap.select('INBOX');
      }, userInitiated: userInitiated);
}

/// Jitter of exactly 1.0 so back-off arithmetic is exact in tests.
class _FixedRandom implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0.5;
  @override
  int nextInt(int max) => 0;
}

DirectMailException _kind(DirectErrorKind k) => DirectMailException(k);

Matcher _throwsKind(DirectErrorKind kind) =>
    throwsA(isA<DirectMailException>().having((e) => e.kind, 'kind', kind));

void main() {
  group('one connection, one operation at a time', () {
    test('operations share a single connection and never overlap', () async {
      final rig = _Rig();
      final log = <String>[];
      var running = 0;
      var maxRunning = 0;
      Future<void> job(String name) => rig.connection.run<void>((imap) async {
        running++;
        maxRunning = max(maxRunning, running);
        log.add('start $name');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        log.add('end $name');
        running--;
      });

      await Future.wait([job('a'), job('b'), job('c')]);

      expect(rig.created, hasLength(1));
      expect(maxRunning, 1);
      expect(log, ['start a', 'end a', 'start b', 'end b', 'start c', 'end c']);
      expect(rig.created.single.count('connect'), 1);
    });

    test('an error in one operation does not stop the queue', () async {
      final rig = _Rig();
      final results = await Future.wait([
        rig.connection.run<int>((_) async => 1),
        rig.connection
            .run<int>((_) async => throw StateError('boom'))
            .then((v) => v, onError: (_) => -1),
        rig.connection.run<int>((_) async => 3),
      ]);
      expect(results, [1, -1, 3]);
      expect(rig.created, hasLength(1));
    });

    test(
      'the connection closes after a quiet spell and reopens when needed',
      () async {
        final rig = _Rig(idleClose: const Duration(milliseconds: 40));
        await rig.ping();
        expect(rig.created.single.isConnected, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(rig.created.single.isConnected, isFalse);
        await rig.ping();
        expect(rig.created, hasLength(2));
      },
    );

    test(
      'work arriving before the quiet spell ends keeps the connection',
      () async {
        final rig = _Rig(idleClose: const Duration(milliseconds: 80));
        await rig.ping();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await rig.ping();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await rig.ping();
        expect(rig.created, hasLength(1));
      },
    );

    test('a closed connection refuses further work', () async {
      final rig = _Rig();
      await rig.ping();
      await rig.connection.close();
      await expectLater(rig.ping(), _throwsKind(DirectErrorKind.offline));
      expect(rig.created.single.isConnected, isFalse);
    });
  });

  group('a refused sign-in', () {
    test('is final: nothing else is tried until the user fixes it', () async {
      final rig = _Rig()..connectErrors.add(_kind(DirectErrorKind.authFailed));

      await expectLater(rig.ping(), _throwsKind(DirectErrorKind.authFailed));
      expect(rig.created, hasLength(1));
      expect(rig.reauthCalls, 1);
      expect(rig.connection.state, DirectConnectionState.needsReauthentication);

      for (var i = 0; i < 5; i++) {
        rig.advance(const Duration(hours: 1));
        await expectLater(
          rig.ping(userInitiated: true),
          _throwsKind(DirectErrorKind.authFailed),
        );
      }
      expect(rig.created, hasLength(1), reason: 'no further attempt, ever');
      expect(rig.reauthCalls, 1, reason: 'reported once');
    });

    test('allows a new attempt after the credentials change', () async {
      final rig = _Rig()..connectErrors.add(_kind(DirectErrorKind.authFailed));
      await expectLater(rig.ping(), _throwsKind(DirectErrorKind.authFailed));

      await rig.connection.credentialsChanged();
      await rig.ping();

      expect(rig.created, hasLength(2));
      expect(rig.recoveredCalls, 1);
      expect(rig.connection.state, DirectConnectionState.ready);
    });

    test('an app-password demand is treated the same way', () async {
      final rig = _Rig()
        ..connectErrors.add(_kind(DirectErrorKind.authRequiresAppPassword));
      await expectLater(
        rig.ping(),
        _throwsKind(DirectErrorKind.authRequiresAppPassword),
      );
      await expectLater(
        rig.ping(userInitiated: true),
        _throwsKind(DirectErrorKind.authRequiresAppPassword),
      );
      expect(rig.created, hasLength(1));
    });
  });

  group('waiting after a failure', () {
    test(
      'an unreachable server is not hammered: 30 s, then 1 min, then 2 min',
      () async {
        final rig = _Rig();
        rig.connectErrors
          ..add(_kind(DirectErrorKind.hostUnreachable))
          ..add(_kind(DirectErrorKind.hostUnreachable))
          ..add(_kind(DirectErrorKind.hostUnreachable));

        await expectLater(
          rig.ping(),
          _throwsKind(DirectErrorKind.hostUnreachable),
        );
        expect(rig.created, hasLength(1));
        expect(
          rig.policy.nextAttemptAt,
          rig.now.add(const Duration(seconds: 30)),
        );

        // Within the wait: refused without touching the network.
        rig.advance(const Duration(seconds: 29));
        await expectLater(
          rig.ping(),
          _throwsKind(DirectErrorKind.hostUnreachable),
        );
        expect(rig.created, hasLength(1));

        rig.advance(const Duration(seconds: 2));
        await expectLater(
          rig.ping(),
          _throwsKind(DirectErrorKind.hostUnreachable),
        );
        expect(rig.created, hasLength(2));
        expect(
          rig.policy.nextAttemptAt!.difference(rig.now),
          const Duration(minutes: 1),
        );

        rig.advance(const Duration(minutes: 1, seconds: 1));
        await expectLater(
          rig.ping(),
          _throwsKind(DirectErrorKind.hostUnreachable),
        );
        expect(
          rig.policy.nextAttemptAt!.difference(rig.now),
          const Duration(minutes: 2),
        );

        // The schedule stops growing at its last step.
        rig.advance(const Duration(minutes: 3));
        rig.connectErrors.add(_kind(DirectErrorKind.hostUnreachable));
        await expectLater(
          rig.ping(),
          _throwsKind(DirectErrorKind.hostUnreachable),
        );
        expect(
          rig.policy.nextAttemptAt!.difference(rig.now),
          const Duration(minutes: 2),
        );
      },
    );

    test('one success clears the waiting', () async {
      final rig = _Rig()..connectErrors.add(_kind(DirectErrorKind.dnsFailure));
      await expectLater(rig.ping(), _throwsKind(DirectErrorKind.dnsFailure));
      rig.advance(const Duration(minutes: 1));
      await rig.ping();
      expect(rig.policy.consecutiveFailures, 0);
      expect(rig.policy.nextAttemptAt, isNull);
    });

    test(
      'a user may retry sooner, but not within 10 s of the last attempt',
      () async {
        final rig = _Rig()
          ..connectErrors.add(_kind(DirectErrorKind.connectionTimeout));
        await expectLater(
          rig.ping(),
          _throwsKind(DirectErrorKind.connectionTimeout),
        );

        rig.advance(const Duration(seconds: 5));
        await expectLater(
          rig.ping(userInitiated: true),
          _throwsKind(DirectErrorKind.connectionTimeout),
        );
        expect(rig.created, hasLength(1), reason: 'too soon even for a user');

        rig.advance(const Duration(seconds: 6));
        await rig.ping(userInitiated: true);
        expect(rig.created, hasLength(2));
      },
    );

    test('a rate limit pauses for 15 minutes, whoever asks', () async {
      final rig = _Rig()..connectErrors.add(_kind(DirectErrorKind.rateLimited));
      await expectLater(rig.ping(), _throwsKind(DirectErrorKind.rateLimited));

      rig.advance(const Duration(minutes: 14));
      await expectLater(
        rig.ping(userInitiated: true),
        _throwsKind(DirectErrorKind.rateLimited),
      );
      expect(rig.created, hasLength(1));

      rig.advance(const Duration(minutes: 2));
      await rig.ping();
      expect(rig.created, hasLength(2));
    });

    test(
      'a refused command (missing folder) says nothing about the server',
      () async {
        final rig = _Rig();
        await expectLater(
          rig.connection.run<void>((imap) => imap.select('Yok')),
          _throwsKind(DirectErrorKind.folderNotFound),
        );
        expect(rig.policy.consecutiveFailures, 0);
        expect(rig.policy.nextAttemptAt, isNull);
        await rig.ping();
        expect(rig.created, hasLength(1), reason: 'the connection was kept');
      },
    );

    test('a connection lost mid-operation is dropped and counted', () async {
      final rig = _Rig();
      await expectLater(
        rig.connection.run<void>((imap) async {
          throw const SocketException('Connection reset by peer');
        }),
        _throwsKind(DirectErrorKind.hostUnreachable),
      );
      expect(rig.created.single.isConnected, isFalse);
      expect(rig.policy.consecutiveFailures, 1);
    });

    test('TLS trouble waits like any connection failure', () async {
      final rig = _Rig()
        ..connectErrors.add(_kind(DirectErrorKind.tlsCertificateInvalid));
      await expectLater(
        rig.ping(),
        _throwsKind(DirectErrorKind.tlsCertificateInvalid),
      );
      expect(rig.policy.nextAttemptAt, isNotNull);
      expect(rig.policy.needsReauthentication, isFalse);
    });
  });

  group('being offline', () {
    test(
      'is reported without contacting the server and builds no waiting',
      () async {
        final rig = _Rig(online: false);
        for (var i = 0; i < 4; i++) {
          await expectLater(rig.ping(), _throwsKind(DirectErrorKind.offline));
        }
        expect(rig.created, isEmpty);
        expect(rig.policy.consecutiveFailures, 0);
        rig.online = true;
        await rig.ping();
        expect(rig.created, hasLength(1));
      },
    );
  });

  group('watching for new mail', () {
    test('forwards pushes and survives other work in between', () async {
      final rig = _Rig();
      final pushes = <ImapPush>[];
      final sub = rig.connection.watch('INBOX').listen(pushes.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.connection.isWatching, isTrue);

      // Other work interrupts the wait and the wait comes back after it.
      await rig.ping();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.connection.isWatching, isTrue);
      expect(rig.created, hasLength(1));
      expect(rig.created.single.count('idle'), 2);

      rig.created.single.pushes.add(ImapPush.newMail);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pushes, [ImapPush.newMail]);

      await sub.cancel();
      expect(rig.connection.isWatching, isFalse);
    });

    test('a server without IDLE ends the watch with a clear reason', () async {
      final rig = _Rig(capabilities: {'IMAP4REV1', 'UIDPLUS'});
      final errors = <Object>[];
      final done = Completer<void>();
      rig.connection
          .watch('INBOX')
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      expect(rig.connection.isWatching, isFalse);
    });

    test('a connect failure reaches the watcher as an error', () async {
      final rig = _Rig()
        ..connectErrors.add(_kind(DirectErrorKind.hostUnreachable));
      final errors = <Object>[];
      rig.connection.watch('INBOX').listen((_) {}, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(errors.single, isA<DirectMailException>());
      expect(
        (errors.single as DirectMailException).kind,
        DirectErrorKind.hostUnreachable,
      );
    });
  });

  group('ConnectionPolicy', () {
    test('jitter stays within ±20 %', () {
      final seen = <int>{};
      for (var seed = 0; seed < 50; seed++) {
        final p = ConnectionPolicy(random: Random(seed));
        p.failed(_kind(DirectErrorKind.hostUnreachable));
        final ms = p.nextAttemptAt!.difference(DateTime.now()).inMilliseconds;
        seen.add(ms ~/ 1000);
        expect(ms, inInclusiveRange(23000, 37000));
      }
      expect(seen.length, greaterThan(1));
    });

    test('offline does not count as a server failure', () {
      final p = ConnectionPolicy();
      p.failed(_kind(DirectErrorKind.offline));
      expect(p.consecutiveFailures, 0);
      expect(p.nextAttemptAt, isNull);
    });

    test('errors that are not about reaching the server are ignored', () {
      final p = ConnectionPolicy();
      for (final k in [
        DirectErrorKind.folderNotFound,
        DirectErrorKind.mailNotFound,
        DirectErrorKind.imapCommandFailed,
        DirectErrorKind.quotaExceeded,
      ]) {
        p.failed(_kind(k));
      }
      expect(p.consecutiveFailures, 0);
      expect(p.needsReauthentication, isFalse);
    });

    test('the categories line up with the HTTP client\'s', () {
      expect(
        _kind(DirectErrorKind.hostUnreachable).category,
        ApiErrorCategory.network,
      );
      expect(
        _kind(DirectErrorKind.connectionTimeout).category,
        ApiErrorCategory.timeout,
      );
    });
  });
}
