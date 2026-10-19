import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/settings_discovery.dart';

const _cpanel = '''<?xml version="1.0"?>
<clientConfig version="1.1">
  <emailProvider id="example.test">
    <incomingServer type="imap">
      <hostname>mail.example.test</hostname>
      <port>993</port>
      <socketType>SSL</socketType>
      <username>%EMAILADDRESS%</username>
    </incomingServer>
    <incomingServer type="pop3">
      <hostname>pop.example.test</hostname>
      <port>995</port>
      <socketType>SSL</socketType>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>mail.example.test</hostname>
      <port>587</port>
      <socketType>STARTTLS</socketType>
      <username>%EMAILLOCALPART%</username>
    </outgoingServer>
  </emailProvider>
</clientConfig>''';

void main() {
  group('known providers', () {
    test('Gmail needs an app password and uses implicit TLS', () {
      final s = SettingsDiscovery.knownProvider('ayse@gmail.com')!;
      expect(s.imap.host, 'imap.gmail.com');
      expect(s.imap.port, 993);
      expect(s.smtp.host, 'smtp.gmail.com');
      expect(s.requiresAppPassword, isTrue);
      expect(s.imap.username, 'ayse@gmail.com');
      expect(s.source, DiscoverySource.known);
    });

    test('Outlook uses STARTTLS for sending', () {
      final s = SettingsDiscovery.knownProvider('a@hotmail.com')!;
      expect(s.smtp.security, MailSecurity.startTls);
      expect(s.smtp.port, 587);
    });

    test('an unknown domain is not a known provider', () {
      expect(SettingsDiscovery.knownProvider('a@kucukfirma.com.tr'), isNull);
      expect(SettingsDiscovery.knownProvider('no-at-sign'), isNull);
    });
  });

  group('published settings', () {
    test('reads IMAP and SMTP, skips POP3, fills the user name', () {
      final s = SettingsDiscovery.parseAutoconfig(
        _cpanel,
        'ayse@example.test',
      )!;
      expect(s.imap.host, 'mail.example.test');
      expect(s.imap.username, 'ayse@example.test');
      expect(s.smtp.port, 587);
      expect(s.smtp.security, MailSecurity.startTls);
      expect(s.smtp.username, 'ayse');
      expect(s.source, DiscoverySource.published);
    });

    test('never accepts an unencrypted server', () {
      final plain = _cpanel.replaceAll('SSL', 'plain');
      expect(
        SettingsDiscovery.parseAutoconfig(plain, 'a@example.test'),
        isNull,
      );
    });

    test('rejects hosts that are not host names', () {
      final bad = _cpanel.replaceAll('mail.example.test', 'evil.test/path');
      expect(SettingsDiscovery.parseAutoconfig(bad, 'a@example.test'), isNull);
    });

    test('is fetched from the domain\'s own autoconfig host', () async {
      final asked = <Uri>[];
      final discovery = SettingsDiscovery(
        client: MockClient((request) async {
          asked.add(request.url);
          return http.Response(_cpanel, 200);
        }),
      );
      final s = await discovery.discover('ayse@example.test');
      expect(s!.source, DiscoverySource.published);
      expect(asked.single.host, 'autoconfig.example.test');
    });

    test('falls back to the well-known path, then to the convention', () async {
      final asked = <Uri>[];
      final discovery = SettingsDiscovery(
        client: MockClient((request) async {
          asked.add(request.url);
          return http.Response('nope', 404);
        }),
      );
      final s = await discovery.discover('ayse@example.test');
      expect(asked.map((u) => u.host), [
        'autoconfig.example.test',
        'example.test',
      ]);
      expect(s!.source, DiscoverySource.guessed);
      expect(s.imap.host, 'mail.example.test');
      expect(s.smtp.port, 465);
    });

    test('a network failure is not an error, just a guess', () async {
      final discovery = SettingsDiscovery(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      final s = await discovery.discover('a@example.test');
      expect(s!.source, DiscoverySource.guessed);
    });

    test('a known provider is answered without asking anyone', () async {
      var calls = 0;
      final discovery = SettingsDiscovery(
        client: MockClient((_) async {
          calls++;
          return http.Response('', 404);
        }),
      );
      await discovery.discover('a@gmail.com');
      expect(calls, 0);
    });

    test('garbage addresses give nothing', () async {
      final discovery = SettingsDiscovery(
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(await discovery.discover('nope'), isNull);
      expect(await discovery.discover('a@bad host'), isNull);
    });
  });
}
