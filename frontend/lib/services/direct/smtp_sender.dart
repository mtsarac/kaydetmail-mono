import 'dart:async';
import 'dart:io';

import 'package:enough_mail_plus/enough_mail.dart'
    show AuthMechanism, MailAddress, SmtpClient, SmtpException;
import 'package:http/http.dart' as http;

import '../api_auth_service.dart' show MailSecurity;
import 'direct_account_setup.dart';
import 'direct_errors.dart';
import 'message_composer.dart';

/// Where a failed submission stopped.
enum SmtpStage { connect, auth, sender, recipient, data, afterData }

/// What the server said about a message it accepted.
class SmtpDelivery {
  const SmtpDelivery({this.serverReply = ''});
  final String serverReply;
}

/// Submits mail to an SMTP server.
///
/// One instance belongs to one account; each [send] uses its own connection.
/// Failures are [DirectMailException]s: ones raised **before** the server
/// accepted the message's data are definite (nothing was delivered); a
/// connection that dies **after** the data was handed over is
/// [DirectErrorKind.deliveryUncertain], which callers must never retry on
/// their own.
abstract interface class SmtpSender {
  /// Largest message the server said it takes, once known.
  int? get maxMessageSize;

  /// Connects, secures the connection and signs in, without sending
  /// anything.
  Future<void> verify();

  Future<SmtpDelivery> send(
    ComposedMessage message, {
    void Function(int sent, int total)? onProgress,
    Future<void>? abort,
  });
}

/// How the connection is secured; [plaintext] exists for tests against a
/// local server and is not reachable from an account.
enum SmtpTransport { tls, startTls, plaintext }

/// [SmtpClient] that notes how far a submission got, which the library does
/// not report: whether the server accepted `DATA`, and what was asked last.
class TrackingSmtpClient extends SmtpClient {
  TrackingSmtpClient(super.clientDomain, {super.onBadCertificate});

  /// The server answered `354`: from here on the message may be delivered.
  bool dataAccepted = false;
  String lastCommand = '';

  void startOver() {
    dataAccepted = false;
    lastCommand = '';
  }

  @override
  void onServerResponse(List<String> responseTexts) {
    if (responseTexts.isNotEmpty && responseTexts.first.startsWith('354')) {
      dataAccepted = true;
    }
    super.onServerResponse(responseTexts);
  }

  @override
  Future<dynamic> writeText(
    String text, [
    dynamic logObject,
    Duration? timeout,
  ]) {
    // Commands are short; a long text is the message body. `RSET` follows a
    // refusal and says nothing about where the exchange stood.
    final upper = text.toUpperCase();
    if (text.length < 512 && upper != 'RSET') lastCommand = upper;
    return super.writeText(text, logObject, timeout);
  }

  SmtpStage get stage {
    if (dataAccepted) return SmtpStage.afterData;
    if (lastCommand.startsWith('MAIL FROM')) return SmtpStage.sender;
    if (lastCommand.startsWith('RCPT TO')) return SmtpStage.recipient;
    if (lastCommand.startsWith('DATA')) return SmtpStage.data;
    if (lastCommand.startsWith('AUTH')) return SmtpStage.auth;
    return SmtpStage.connect;
  }
}

class EnoughSmtpSender implements SmtpSender {
  EnoughSmtpSender({
    required DirectEndpoint endpoint,
    required this.password,
    required this.clientDomain,
    SmtpTransport? transport,
    this.connectTimeout = const Duration(seconds: 20),
    this.sendTimeout = const Duration(minutes: 2),
  }) : _endpoint = endpoint,
       _transport =
           transport ??
           (endpoint.security == MailSecurity.startTls
               ? SmtpTransport.startTls
               : SmtpTransport.tls);

  final DirectEndpoint _endpoint;
  final String password;

  /// The name announced in `EHLO`: the sender's domain.
  final String clientDomain;
  final SmtpTransport _transport;
  final Duration connectTimeout;
  final Duration sendTimeout;

  int? _maxMessageSize;

  @override
  int? get maxMessageSize => _maxMessageSize;

  @override
  Future<void> verify() async {
    final client = TrackingSmtpClient(clientDomain);
    try {
      await _open(client);
      await client.quit();
    } on Object catch (error) {
      throw _failure(error, client);
    } finally {
      await _close(client);
    }
  }

  @override
  Future<SmtpDelivery> send(
    ComposedMessage message, {
    void Function(int sent, int total)? onProgress,
    Future<void>? abort,
  }) async {
    final client = TrackingSmtpClient(clientDomain);
    var aborted = false;
    unawaited(
      abort?.then((_) {
        aborted = true;
        unawaited(client.disconnect());
      }),
    );
    try {
      await _open(client);
      if (aborted) throw http.RequestAbortedException();
      final limit = client.serverInfo.maxMessageSize;
      _maxMessageSize = limit;
      if (limit != null && limit > 0 && message.size > limit) {
        throw DirectMailException(DirectErrorKind.messageTooLarge);
      }
      client.startOver();
      onProgress?.call(0, message.size);
      final response = await client
          .sendMessageText(
            message.source,
            MailAddress(null, message.envelopeFrom),
            [for (final r in message.envelopeRecipients) MailAddress(null, r)],
          )
          .timeout(sendTimeout);
      onProgress?.call(message.size, message.size);
      try {
        await client.quit();
      } on Object {
        // The message is accepted; how the goodbye goes does not matter.
      }
      return SmtpDelivery(serverReply: response.message ?? '');
    } on Object catch (error) {
      if (aborted && !client.dataAccepted) {
        throw http.RequestAbortedException();
      }
      throw _failure(error, client);
    } finally {
      await _close(client);
    }
  }

  // --- Connection ---------------------------------------------------------------------

  Future<void> _open(TrackingSmtpClient client) async {
    await client.connectToServer(
      _endpoint.host,
      _endpoint.port,
      isSecure: _transport == SmtpTransport.tls,
      timeout: connectTimeout,
    );
    await client.ehlo();
    if (_transport == SmtpTransport.startTls) {
      // Never fall back to clear text: no STARTTLS offered, no sign-in.
      if (!client.serverInfo.supportsStartTls) {
        throw DirectMailException(DirectErrorKind.tlsHandshakeFailed);
      }
      await client.startTls();
    }
    client.lastCommand = 'AUTH';
    final mechanisms = client.serverInfo;
    final mechanism = mechanisms.supportsAuth(AuthMechanism.plain)
        ? AuthMechanism.plain
        : mechanisms.supportsAuth(AuthMechanism.login)
        ? AuthMechanism.login
        : mechanisms.supportsAuth(AuthMechanism.cramMd5)
        ? AuthMechanism.cramMd5
        : AuthMechanism.plain;
    await client.authenticate(_endpoint.username, password, mechanism);
    _maxMessageSize = client.serverInfo.maxMessageSize;
  }

  Future<void> _close(TrackingSmtpClient client) async {
    try {
      await client.disconnect();
    } on Object {
      // Already gone.
    }
  }

  // --- Failures ----------------------------------------------------------------------------

  DirectMailException _failure(Object error, TrackingSmtpClient client) {
    if (error is DirectMailException) return error;
    final stage = client.stage;
    if (error is SmtpException) {
      // Client-side failures (connection lost, disconnected) have no server
      // reply behind them; anything else is the server's answer.
      if (_isClientSideMessage(error)) return _connectionLost(error, client);
      final reply = error.response;
      final code = reply.responseLines.isEmpty ? null : reply.code;
      return classifyReply(code, error.message ?? '', stage);
    }
    if (error is TimeoutException || error is SocketException) {
      return _connectionLost(error, client);
    }
    return client.dataAccepted
        ? DirectMailException(DirectErrorKind.deliveryUncertain, cause: error)
        : DirectMailException.from(error);
  }

  static bool _isClientSideMessage(SmtpException error) {
    final text = (error.message ?? '').toLowerCase();
    return text.contains('connection lost') ||
        text.contains('client disconnected') ||
        text.contains('connection closed');
  }

  DirectMailException _connectionLost(
    Object error,
    TrackingSmtpClient client,
  ) => client.dataAccepted
      ? DirectMailException(DirectErrorKind.deliveryUncertain, cause: error)
      : error is SmtpException
      ? DirectMailException(DirectErrorKind.hostUnreachable, cause: error)
      : DirectMailException.from(error);

  /// Turns a server reply into the error the user should see. [code] is null
  /// when there was no usable reply.
  static DirectMailException classifyReply(
    int? code,
    String message,
    SmtpStage stage,
  ) {
    final text = message.toLowerCase();
    final permanent = code != null && code >= 500;
    DirectMailException error(DirectErrorKind kind) =>
        DirectMailException(kind);

    bool has(List<String> words) => words.any(text.contains);

    if (stage == SmtpStage.auth) {
      if (code != null && code >= 400 && code < 500 && code != 454) {
        return error(DirectErrorKind.temporaryFailure);
      }
      if (code == 454) return error(DirectErrorKind.temporaryFailure);
      if (has([
        'application-specific',
        'app password',
        'app-password',
        'less secure',
        'application specific',
      ])) {
        return error(DirectErrorKind.authRequiresAppPassword);
      }
      return error(DirectErrorKind.authFailed);
    }
    if (has([
          'too many',
          'rate limit',
          'ratelimit',
          'throttl',
          'sending limit',
        ]) ||
        (has(['exceeded']) &&
            has(['messages', 'connections', 'per hour', 'per day']))) {
      return error(DirectErrorKind.rateLimited);
    }
    if (code == 552 && stage != SmtpStage.recipient ||
        has(['message size', 'too large', 'too big', 'size limit']) &&
            stage != SmtpStage.recipient) {
      return error(DirectErrorKind.messageTooLarge);
    }
    if (!permanent) return error(DirectErrorKind.temporaryFailure);
    return switch (stage) {
      SmtpStage.sender => error(DirectErrorKind.smtpSenderRejected),
      SmtpStage.recipient => error(DirectErrorKind.smtpRecipientRejected),
      _ => error(DirectErrorKind.smtpRejected),
    };
  }
}
