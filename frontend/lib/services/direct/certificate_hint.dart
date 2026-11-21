import 'dart:async';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart' show X509Utils;

import '../api_auth_service.dart' show MailSecurity;
import 'direct_account_setup.dart';

/// Finds out which host names a mail server's certificate really covers, so a
/// "certificate does not match" failure can say what to type instead.
///
/// The classic case is shared hosting: the mailbox is `info@mydomain.com`,
/// the user types `mail.mydomain.com`, but the server presents a certificate
/// for the hosting company's own name. The connection is never trusted for
/// anything here: the certificate is read and the socket closed.
class CertificateHint {
  const CertificateHint._();

  /// The best replacement for [configured] among the certificate's [names],
  /// or null when none is a sensible suggestion.
  ///
  /// A name that already matched would not have failed, so wildcards are only
  /// used to build a suggestion when they cover a name that looks like a mail
  /// host of the same domain. Mail-looking names (`imap.`, `mail.`, `smtp.`)
  /// win over others.
  static String? suggest(String configured, Iterable<String> names) {
    final host = configured.trim().toLowerCase();
    final concrete = <String>[];
    for (final raw in names) {
      final name = raw.trim().toLowerCase();
      if (name.isEmpty || name.startsWith('*.') || name == host) continue;
      if (!DirectEndpoint.isValidHostName(name)) continue;
      if (!concrete.contains(name)) concrete.add(name);
    }
    if (concrete.isEmpty) return null;
    bool mailLike(String n) =>
        n.startsWith('imap.') ||
        n.startsWith('smtp.') ||
        n.startsWith('mail.') ||
        n.startsWith('pop.');
    return concrete.firstWhere(mailLike, orElse: () => concrete.first);
  }

  /// The DNS names of the certificate [server] presents on its implicit-TLS
  /// port; empty when it cannot be read (STARTTLS ports are not probed).
  static Future<List<String>> namesPresentedBy(
    DirectEndpoint server, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (server.security != MailSecurity.sslOnConnect) return const [];
    X509Certificate? seen;
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        server.host,
        server.port,
        timeout: timeout,
        onBadCertificate: (cert) {
          seen = cert;
          return true;
        },
      );
      seen ??= socket.peerCertificate;
    } on Object {
      // Not reachable or not TLS: nothing to suggest.
    } finally {
      await socket?.close();
      socket?.destroy();
    }
    final cert = seen;
    return cert == null ? const [] : namesIn(cert.pem);
  }

  /// DNS names of a PEM certificate: the subject alternative names, else the
  /// common name.
  static List<String> namesIn(String pem) {
    try {
      final data = X509Utils.x509CertificateFromPem(pem);
      final alt = data.tbsCertificate?.extensions?.subjectAlternativNames;
      if (alt != null && alt.isNotEmpty) return List.of(alt);
      final cn = data.tbsCertificate?.subject['2.5.4.3'];
      return cn == null ? const [] : [cn];
    } catch (_) {
      return const [];
    }
  }

  /// [suggest]ed host for [server], read from the certificate it presents.
  static Future<String?> forServer(DirectEndpoint server) async =>
      suggest(server.host, await namesPresentedBy(server));
}
