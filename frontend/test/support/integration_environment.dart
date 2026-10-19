import 'dart:io';

/// Settings for the tests that talk to a real mail server (GreenMail). Same
/// variables as the backend's tests:
///
/// * `MAILCLIENT_TEST_GREENMAIL=1` (or `…_HOST`) switches them on;
/// * `MAILCLIENT_SKIP_INTEGRATION` switches them off again;
/// * `…_IMAP` / `…_SMTP` set the ports, `…_USER` / `…_PASSWORD` the account.
///
/// Start one with
/// `docker run -p 3143:3143 -p 3025:3025 -e GREENMAIL_OPTS="-Dgreenmail.setup.test.all
/// -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=test@localhost:test123"
/// greenmail/standalone:2.1.8`.
class IntegrationEnvironment {
  const IntegrationEnvironment._();

  static String? _value(String name) {
    final v = Platform.environment[name];
    return v == null || v.isEmpty ? null : v;
  }

  static bool get skip => _value('MAILCLIENT_SKIP_INTEGRATION') != null;

  static bool get greenMailEnabled =>
      !skip &&
      (_value('MAILCLIENT_TEST_GREENMAIL') == '1' ||
          _value('MAILCLIENT_TEST_GREENMAIL_HOST') != null);

  static String get host =>
      _value('MAILCLIENT_TEST_GREENMAIL_HOST') ?? '127.0.0.1';
  static int get imapPort =>
      int.tryParse(_value('MAILCLIENT_TEST_GREENMAIL_IMAP') ?? '') ?? 3143;
  static int get smtpPort =>
      int.tryParse(_value('MAILCLIENT_TEST_GREENMAIL_SMTP') ?? '') ?? 3025;
  static String get user =>
      _value('MAILCLIENT_TEST_GREENMAIL_USER') ?? 'test@localhost';
  static String get password =>
      _value('MAILCLIENT_TEST_GREENMAIL_PASSWORD') ?? 'test123';

  /// `skip:` argument for tests that need GreenMail.
  static Object? get skipUnlessGreenMail => greenMailEnabled
      ? false
      : 'needs GreenMail: set MAILCLIENT_TEST_GREENMAIL=1 (see test/support/integration_environment.dart)';
}
