import 'dart:async';

import 'package:http/http.dart' as http;

import '../api_auth_service.dart' show MailSecurity;
import 'direct_account_setup.dart';

/// Where a set of suggested server settings came from, which tells the
/// screen how much to trust it.
enum DiscoverySource {
  /// A provider this app knows by name.
  known,

  /// Published by the mail domain itself (Mozilla autoconfig).
  published,

  /// Nothing was published: the usual `mail.<domain>` convention.
  guessed,
}

/// Suggested servers for a mailbox.
class DiscoveredSettings {
  const DiscoveredSettings({
    required this.imap,
    required this.smtp,
    required this.source,
    this.requiresAppPassword = false,
  });

  final DirectEndpoint imap;
  final DirectEndpoint smtp;
  final DiscoverySource source;

  /// The provider rejects the account password for mail clients; the user
  /// has to create an app-specific one.
  final bool requiresAppPassword;
}

/// Works out IMAP/SMTP settings from an address, without any KaydetMail
/// service: a table of well-known providers, the domain's own published
/// autoconfig file, and finally the `mail.<domain>` convention.
///
/// Only the mail domain's own servers are asked, and only for its public
/// configuration file; nothing about the user is sent to anyone else.
class SettingsDiscovery {
  SettingsDiscovery({
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  void close() {
    if (_ownsClient) _client.close();
  }

  static String? domainOf(String email) {
    final at = email.trim().lastIndexOf('@');
    if (at <= 0 || at == email.trim().length - 1) return null;
    return email.trim().substring(at + 1).toLowerCase();
  }

  Future<DiscoveredSettings?> discover(String email) async {
    final domain = domainOf(email);
    if (domain == null || !DirectEndpoint.isValidHostName(domain)) return null;
    final known = knownProvider(email);
    if (known != null) return known;
    final published = await _published(email.trim(), domain);
    return published ?? guess(email);
  }

  // --- Known providers -----------------------------------------------------------

  static DiscoveredSettings? knownProvider(String email) {
    final domain = domainOf(email);
    if (domain == null) return null;
    final user = email.trim();
    DirectEndpoint ep(String host, int port, MailSecurity s) =>
        DirectEndpoint(host: host, port: port, security: s, username: user);
    const tls = MailSecurity.sslOnConnect;
    const start = MailSecurity.startTls;
    switch (domain) {
      case 'gmail.com' || 'googlemail.com':
        return DiscoveredSettings(
          imap: ep('imap.gmail.com', 993, tls),
          smtp: ep('smtp.gmail.com', 465, tls),
          source: DiscoverySource.known,
          requiresAppPassword: true,
        );
      case 'outlook.com' || 'hotmail.com' || 'live.com' || 'msn.com':
        return DiscoveredSettings(
          imap: ep('outlook.office365.com', 993, tls),
          smtp: ep('smtp-mail.outlook.com', 587, start),
          source: DiscoverySource.known,
          requiresAppPassword: true,
        );
      case 'yahoo.com' || 'ymail.com' || 'yahoo.com.tr':
        return DiscoveredSettings(
          imap: ep('imap.mail.yahoo.com', 993, tls),
          smtp: ep('smtp.mail.yahoo.com', 465, tls),
          source: DiscoverySource.known,
          requiresAppPassword: true,
        );
      case 'icloud.com' || 'me.com' || 'mac.com':
        return DiscoveredSettings(
          imap: ep('imap.mail.me.com', 993, tls),
          smtp: ep('smtp.mail.me.com', 587, start),
          source: DiscoverySource.known,
          requiresAppPassword: true,
        );
      case 'yandex.com' || 'yandex.ru' || 'ya.ru':
        return DiscoveredSettings(
          imap: ep('imap.yandex.com', 993, tls),
          smtp: ep('smtp.yandex.com', 465, tls),
          source: DiscoverySource.known,
          requiresAppPassword: true,
        );
      case 'zoho.com':
        return DiscoveredSettings(
          imap: ep('imap.zoho.com', 993, tls),
          smtp: ep('smtp.zoho.com', 465, tls),
          source: DiscoverySource.known,
        );
    }
    return null;
  }

  /// The `mail.<domain>` convention (cPanel and most hosting panels).
  static DiscoveredSettings guess(String email) {
    final domain = domainOf(email) ?? '';
    final user = email.trim();
    DirectEndpoint ep(int port) => DirectEndpoint(
      host: 'mail.$domain',
      port: port,
      security: MailSecurity.sslOnConnect,
      username: user,
    );
    return DiscoveredSettings(
      imap: ep(993),
      smtp: ep(465),
      source: DiscoverySource.guessed,
    );
  }

  // --- Published by the domain --------------------------------------------------------

  Future<DiscoveredSettings?> _published(String email, String domain) async {
    final encoded = Uri.encodeQueryComponent(email);
    final urls = [
      'https://autoconfig.$domain/mail/config-v1.1.xml?emailaddress=$encoded',
      'https://$domain/.well-known/autoconfig/mail/config-v1.1.xml',
    ];
    for (final url in urls) {
      try {
        final response = await _client.get(Uri.parse(url)).timeout(timeout);
        if (response.statusCode != 200) continue;
        final parsed = parseAutoconfig(response.body, email);
        if (parsed != null) return parsed;
      } on Object {
        // Not published here; try the next place.
      }
    }
    return null;
  }

  /// Reads a Mozilla autoconfig document. Only the incoming IMAP and outgoing
  /// SMTP servers matter; unencrypted ones are never accepted.
  static DiscoveredSettings? parseAutoconfig(String xml, String email) {
    final imap = _server(xml, 'incomingServer', 'imap', email);
    final smtp = _server(xml, 'outgoingServer', 'smtp', email);
    if (imap == null || smtp == null) return null;
    return DiscoveredSettings(
      imap: imap,
      smtp: smtp,
      source: DiscoverySource.published,
    );
  }

  static DirectEndpoint? _server(
    String xml,
    String element,
    String type,
    String email,
  ) {
    final blocks = RegExp(
      '<$element\\s+type="$type"\\s*>(.*?)</$element>',
      dotAll: true,
    ).allMatches(xml);
    for (final block in blocks) {
      final body = block.group(1)!;
      String? tag(String name) =>
          RegExp('<$name>\\s*([^<]*?)\\s*</$name>').firstMatch(body)?.group(1);
      final host = tag('hostname')
          ?.replaceAll('%EMAILDOMAIN%', domainOf(email) ?? '');
      final port = int.tryParse(tag('port') ?? '');
      final socket = tag('socketType')?.toUpperCase();
      if (host == null || port == null) continue;
      final security = switch (socket) {
        'SSL' => MailSecurity.sslOnConnect,
        'STARTTLS' => MailSecurity.startTls,
        _ => null,
      };
      if (security == null) continue;
      final at = email.indexOf('@');
      final username = (tag('username') ?? '%EMAILADDRESS%')
          .replaceAll('%EMAILADDRESS%', email)
          .replaceAll('%EMAILLOCALPART%', email.substring(0, at))
          .replaceAll('%EMAILDOMAIN%', email.substring(at + 1));
      final endpoint = DirectEndpoint(
        host: host,
        port: port,
        security: security,
        username: username,
      );
      if (endpoint.problem == null) return endpoint;
    }
    return null;
  }
}
