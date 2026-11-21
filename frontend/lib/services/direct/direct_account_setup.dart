import 'package:flutter/foundation.dart';

import '../api_auth_service.dart' show MailSecurity;

/// One mail-server endpoint of a direct account (IMAP or SMTP).
///
/// Plain, unencrypted connections are not offered: [security] is implicit
/// TLS or STARTTLS, and the certificate is always verified.
@immutable
class DirectEndpoint {
  const DirectEndpoint({
    required this.host,
    required this.port,
    required this.security,
    required this.username,
  });

  factory DirectEndpoint.fromJson(Map<String, dynamic> json) => DirectEndpoint(
    host: json['host'] as String,
    port: json['port'] as int,
    security: json['security'] == 'starttls'
        ? MailSecurity.startTls
        : MailSecurity.sslOnConnect,
    username: json['username'] as String,
  );

  final String host;
  final int port;
  final MailSecurity security;

  /// The login name. Often the full address, sometimes only its local part;
  /// IMAP and SMTP may use different ones.
  final String username;

  DirectEndpoint copyWith({
    String? host,
    int? port,
    MailSecurity? security,
    String? username,
  }) => DirectEndpoint(
    host: host ?? this.host,
    port: port ?? this.port,
    security: security ?? this.security,
    username: username ?? this.username,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'security': security == MailSecurity.startTls ? 'starttls' : 'tls',
    'username': username,
  };

  /// Null when the endpoint is usable; otherwise which field is wrong.
  DirectSetupProblem? get problem {
    if (!isValidHostName(host)) return DirectSetupProblem.host;
    if (port < 1 || port > 65535) return DirectSetupProblem.port;
    if (username.trim().isEmpty) return DirectSetupProblem.username;
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DirectEndpoint &&
      other.host == host &&
      other.port == port &&
      other.security == security &&
      other.username == username;

  @override
  int get hashCode => Object.hash(host, port, security, username);

  /// A DNS name or IP literal, nothing that could smuggle a scheme, path or
  /// whitespace into a socket address.
  static bool isValidHostName(String value) {
    final host = value.trim();
    if (host.isEmpty || host.length > 253) return false;
    return RegExp(
      r'^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*'
      r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
    ).hasMatch(host);
  }
}

enum DirectSetupProblem { email, host, port, username, password }

/// What the user enters to add a direct account.
@immutable
class DirectAccountSetup {
  const DirectAccountSetup({
    required this.email,
    required this.displayName,
    required this.password,
    required this.imap,
    required this.smtp,
    this.smtpPassword,
  });

  final String email;
  final String displayName;
  final String password;
  final DirectEndpoint imap;
  final DirectEndpoint smtp;

  /// Only when the outgoing server wants a different password; otherwise the
  /// account [password] is used for both.
  final String? smtpPassword;

  String get effectiveSmtpPassword => smtpPassword ?? password;

  /// The first field that is wrong, or null when the setup can be tried.
  DirectSetupProblem? get problem {
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim())) {
      return DirectSetupProblem.email;
    }
    if (password.isEmpty) return DirectSetupProblem.password;
    return imap.problem ?? smtp.problem;
  }

  DirectAccountSetup copyWith({
    String? email,
    String? displayName,
    String? password,
    DirectEndpoint? imap,
    DirectEndpoint? smtp,
    String? smtpPassword,
  }) => DirectAccountSetup(
    email: email ?? this.email,
    displayName: displayName ?? this.displayName,
    password: password ?? this.password,
    imap: imap ?? this.imap,
    smtp: smtp ?? this.smtp,
    smtpPassword: smtpPassword ?? this.smtpPassword,
  );
}

/// A stored direct account: everything except the passwords, which live in
/// the secure credential store.
@immutable
class DirectAccountConfig {
  const DirectAccountConfig({
    required this.id,
    required this.email,
    required this.displayName,
    required this.imap,
    required this.smtp,
    this.saveSentCopy = true,
  });

  final String id;
  final String email;
  final String displayName;
  final DirectEndpoint imap;
  final DirectEndpoint smtp;

  /// Append sent mail to the Sent folder ourselves. Servers that file a copy
  /// on their own (Gmail) are detected at send time regardless of this flag.
  final bool saveSentCopy;

  DirectAccountConfig copyWith({
    String? displayName,
    DirectEndpoint? imap,
    DirectEndpoint? smtp,
    bool? saveSentCopy,
  }) => DirectAccountConfig(
    id: id,
    email: email,
    displayName: displayName ?? this.displayName,
    imap: imap ?? this.imap,
    smtp: smtp ?? this.smtp,
    saveSentCopy: saveSentCopy ?? this.saveSentCopy,
  );
}
