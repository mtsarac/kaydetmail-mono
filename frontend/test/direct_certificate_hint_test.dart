import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/certificate_hint.dart';
import 'package:kaydetmail/services/direct/direct_account_setup.dart';

/// Makes a throw-away self-signed certificate for [names]. Generated while
/// the tests run, never stored in the repository.
Future<({String cert, String key})?> _makeCertificate(
  Directory dir,
  List<String> names,
) async {
  final cert = '${dir.path}/cert.pem';
  final key = '${dir.path}/key.pem';
  try {
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '2',
      '-subj',
      '/CN=${names.first}',
      '-addext',
      'subjectAltName=${names.map((n) => 'DNS:$n').join(',')}',
    ]);
    if (result.exitCode != 0) return null;
    return (cert: cert, key: key);
  } on ProcessException {
    return null;
  }
}

void main() {
  group('suggesting a host', () {
    test('prefers a mail-looking name of the certificate', () {
      expect(
        CertificateHint.suggest('mail.alanadim.com', [
          'sunucu12.hosting.example',
          'mail.sunucu12.hosting.example',
          '*.hosting.example',
        ]),
        'mail.sunucu12.hosting.example',
      );
    });

    test('falls back to the first concrete name', () {
      expect(
        CertificateHint.suggest('mail.alanadim.com', [
          'sunucu12.hosting.example',
        ]),
        'sunucu12.hosting.example',
      );
    });

    test('has nothing to say about wildcards only, or the same host', () {
      expect(
        CertificateHint.suggest('a.example.com', ['*.other.example']),
        isNull,
      );
      expect(
        CertificateHint.suggest('a.example.com', ['A.example.com']),
        isNull,
      );
      expect(CertificateHint.suggest('a.example.com', const []), isNull);
    });

    test('ignores anything that is not a plain host name', () {
      expect(
        CertificateHint.suggest('a.example.com', [
          'bad name',
          'x/y',
          'ok.example.org',
        ]),
        'ok.example.org',
      );
    });
  });

  group('reading the certificate a server presents', () {
    late Directory dir;
    SecureServerSocket? server;

    setUp(() => dir = Directory.systemTemp.createTempSync('kaydet_tls_'));
    tearDown(() async {
      await server?.close();
      server = null;
      dir.deleteSync(recursive: true);
    });

    test('finds the names and the host to use instead', () async {
      final made = await _makeCertificate(dir, [
        'sunucu12.hosting.example',
        'mail.sunucu12.hosting.example',
      ]);
      if (made == null) {
        markTestSkipped('openssl is not available');
        return;
      }
      final context = SecurityContext()
        ..useCertificateChain(made.cert)
        ..usePrivateKey(made.key);
      server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server!.listen((socket) => socket.destroy(), onError: (_) {});

      // The user typed a name the certificate does not cover.
      final endpoint = DirectEndpoint(
        host: 'localhost',
        port: server!.port,
        security: MailSecurity.sslOnConnect,
        username: 'u',
      );
      final names = await CertificateHint.namesPresentedBy(endpoint);
      expect(
        names,
        containsAll([
          'sunucu12.hosting.example',
          'mail.sunucu12.hosting.example',
        ]),
      );
      expect(
        await CertificateHint.forServer(endpoint),
        'mail.sunucu12.hosting.example',
      );
    });

    test('a STARTTLS port or a closed port yields no suggestion', () async {
      final starttls = DirectEndpoint(
        host: 'localhost',
        port: 1,
        security: MailSecurity.startTls,
        username: 'u',
      );
      expect(await CertificateHint.forServer(starttls), isNull);
      final closed = DirectEndpoint(
        host: '127.0.0.1',
        port: 1,
        security: MailSecurity.sslOnConnect,
        username: 'u',
      );
      expect(await CertificateHint.forServer(closed), isNull);
    });
  });
}
