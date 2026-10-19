import 'dart:async';
import 'dart:io';

import '../../l10n/l10n.dart';
import '../api_exception.dart';

/// Everything that can go wrong talking to a mail server from this device,
/// named in terms the user can act on. Raw protocol text never reaches the UI
/// or the logs: it stays in [DirectMailException.cause] for debugging only.
enum DirectErrorKind {
  /// The device has no usable network. Same code the HTTP client uses, so
  /// the outbox treats it as "never reached the server, retry later".
  offline('network_unavailable', 0, ApiErrorCategory.network),
  dnsFailure('dns_failure', 0, ApiErrorCategory.network),
  hostUnreachable('host_unreachable', 0, ApiErrorCategory.network),

  /// Same code the HTTP client uses for a timeout.
  connectionTimeout('request_timeout', 0, ApiErrorCategory.timeout),
  tlsHandshakeFailed('tls_handshake_failed', 495, ApiErrorCategory.request),
  tlsCertificateInvalid(
    'tls_certificate_invalid',
    495,
    ApiErrorCategory.request,
  ),
  authFailed('auth_failed', 401, ApiErrorCategory.authentication),
  authRequiresAppPassword(
    'auth_requires_app_password',
    401,
    ApiErrorCategory.authentication,
  ),
  authMethodUnsupported(
    'auth_method_unsupported',
    401,
    ApiErrorCategory.authentication,
  ),
  imapCommandFailed('imap_command_failed', 502, ApiErrorCategory.server),
  smtpRejected('smtp_rejected', 422, ApiErrorCategory.request),
  smtpSenderRejected('smtp_sender_rejected', 422, ApiErrorCategory.request),
  smtpRecipientRejected(
    'smtp_recipient_rejected',
    422,
    ApiErrorCategory.request,
  ),
  messageTooLarge('message_too_large', 413, ApiErrorCategory.request),
  unsupportedOperation('unsupported_operation', 501, ApiErrorCategory.request),
  capabilityMissing('capability_missing', 501, ApiErrorCategory.request),
  mailboxChanged('mailbox_changed', 409, ApiErrorCategory.request),
  folderNotFound('mail_folder_not_found', 404, ApiErrorCategory.request),
  mailNotFound('mail_not_found', 404, ApiErrorCategory.request),
  quotaExceeded('quota_exceeded', 507, ApiErrorCategory.request),

  /// The same mailbox is already connected on this device. Same code the
  /// backend uses.
  accountExists('mail_account_already_exists', 409, ApiErrorCategory.request),
  rateLimited('rate_limited', 429, ApiErrorCategory.server),
  temporaryFailure('temporary_failure', 503, ApiErrorCategory.server),

  /// The message may already have been accepted; never resend automatically.
  /// Same code the backend uses for an unknown send result.
  deliveryUncertain('delivery_unknown', 504, ApiErrorCategory.server);

  const DirectErrorKind(this.code, this.status, this.category);

  /// Stable, machine-readable. Shared with the backend where it means the
  /// same thing so existing handling keeps working.
  final String code;
  final int status;
  final ApiErrorCategory category;
}

/// A failure of a direct (IMAP/SMTP) account. It is an [ApiException] on
/// purpose: every place that already reacts to API failures (offline
/// detection, outbox classification, [friendlyErrorMessage]) keeps working
/// for direct accounts without being touched.
class DirectMailException extends ApiException {
  DirectMailException(
    this.kind, {
    this.suggestedHost,
    this.cause,
    this.endpoint,
  }) : super(status: kind.status, code: kind.code);

  final DirectErrorKind kind;

  /// For [DirectErrorKind.tlsCertificateInvalid]: a host name the server's
  /// certificate really covers (the user can try it as the server name).
  final String? suggestedHost;

  /// Which server a setup failure was about: `imap` or `smtp`.
  final String? endpoint;

  /// The underlying error, for debugging. Never shown, never logged.
  final Object? cause;

  @override
  ApiErrorCategory get category => kind.category;

  @override
  String get userMessage => switch (kind) {
    DirectErrorKind.dnsFailure => l10nNow.directDnsFailure,
    DirectErrorKind.hostUnreachable => l10nNow.directHostUnreachable,
    DirectErrorKind.tlsHandshakeFailed => l10nNow.directTlsHandshakeFailed,
    DirectErrorKind.tlsCertificateInvalid =>
      suggestedHost == null
          ? l10nNow.directTlsCertificateInvalid
          : l10nNow.directTlsHostMismatch(suggestedHost!),
    DirectErrorKind.authFailed => l10nNow.directAuthFailed,
    DirectErrorKind.authRequiresAppPassword =>
      l10nNow.directAuthRequiresAppPassword,
    DirectErrorKind.authMethodUnsupported =>
      l10nNow.directAuthMethodUnsupported,
    DirectErrorKind.imapCommandFailed => l10nNow.directImapCommandFailed,
    DirectErrorKind.smtpRejected => l10nNow.directSmtpRejected,
    DirectErrorKind.smtpSenderRejected => l10nNow.directSmtpSenderRejected,
    DirectErrorKind.smtpRecipientRejected =>
      l10nNow.directSmtpRecipientRejected,
    DirectErrorKind.messageTooLarge => l10nNow.directMessageTooLarge,
    DirectErrorKind.unsupportedOperation => l10nNow.thisActionIsntSupportedFor,
    DirectErrorKind.capabilityMissing => l10nNow.directCapabilityMissing,
    DirectErrorKind.mailboxChanged => l10nNow.theMailboxChangedRefreshAnd,
    DirectErrorKind.quotaExceeded => l10nNow.directQuotaExceeded,
    DirectErrorKind.rateLimited => l10nNow.directRateLimited,
    DirectErrorKind.temporaryFailure => l10nNow.directTemporaryFailure,
    // offline, connectionTimeout, folderNotFound, mailNotFound and
    // deliveryUncertain share a code with an API error that already has text.
    _ => super.userMessage,
  };

  @override
  String toString() => 'DirectMailException(${kind.code})';

  /// Maps any failure raised while talking to a mail server to a
  /// [DirectMailException]. [DirectMailException]s pass through unchanged.
  ///
  /// Authentication failures cannot be told apart from other IMAP/SMTP
  /// rejections here — the protocol layers throw the right kind themselves
  /// where they know it (a rejected LOGIN, a `535` reply). This handles what
  /// the sockets and the TLS stack raise.
  static DirectMailException from(Object error) {
    if (error is DirectMailException) return error;
    if (error is TimeoutException) {
      return DirectMailException(
        DirectErrorKind.connectionTimeout,
        cause: error,
      );
    }
    if (error is HandshakeException || error is TlsException) {
      return DirectMailException(
        _isCertificateProblem(error.toString())
            ? DirectErrorKind.tlsCertificateInvalid
            : DirectErrorKind.tlsHandshakeFailed,
        cause: error,
      );
    }
    if (error is SocketException) return _fromSocket(error);
    return DirectMailException(DirectErrorKind.imapCommandFailed, cause: error);
  }

  static bool _isCertificateProblem(String text) {
    final lower = text.toLowerCase();
    return lower.contains('certificate') ||
        lower.contains('hostname mismatch') ||
        lower.contains('self signed') ||
        lower.contains('self-signed') ||
        lower.contains('unable to get local issuer');
  }

  static DirectMailException _fromSocket(SocketException error) {
    final text = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    final code = error.osError?.errorCode;
    final DirectErrorKind kind;
    if (text.contains('failed host lookup') ||
        text.contains('nodename nor servname') ||
        text.contains('name or service not known') ||
        text.contains('no address associated') ||
        text.contains('temporary failure in name resolution')) {
      kind = DirectErrorKind.dnsFailure;
    } else if (text.contains('timed out') ||
        code == 110 ||
        code == 60 ||
        code == 10060) {
      kind = DirectErrorKind.connectionTimeout;
    } else {
      // Refused, no route, reset, closed: the server cannot be reached.
      kind = DirectErrorKind.hostUnreachable;
    }
    return DirectMailException(kind, cause: error);
  }
}
