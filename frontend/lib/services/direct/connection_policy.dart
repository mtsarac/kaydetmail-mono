import 'dart:math';

import '../api_exception.dart';
import 'direct_errors.dart';

/// When a direct account may talk to its mail server again after a failure.
///
/// Mail servers, cPanel's in particular, answer repeated bad logins and
/// reconnect storms by blocking the client's IP address. So:
///
/// * a refused sign-in is **never** retried by the app: the account waits for
///   the user to correct the password ([needsReauthentication]);
/// * a server that says "too many" / "limit" is left alone for at least
///   [rateLimitQuiet];
/// * network and temporary failures back off 30 s, 1, 2, 5, 15, 30 minutes
///   (±20 %), and the clock resets only after something succeeds;
/// * a user pulling to refresh may try again after [manualRetryAfter], but a
///   user can neither force a refused sign-in nor skip a rate-limit pause.
class ConnectionPolicy {
  ConnectionPolicy({
    DateTime Function()? clock,
    Random? random,
    this.schedule = const [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 30),
    ],
    this.rateLimitQuiet = const Duration(minutes: 15),
    this.manualRetryAfter = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random();

  final DateTime Function() _clock;
  final Random _random;
  final List<Duration> schedule;
  final Duration rateLimitQuiet;
  final Duration manualRetryAfter;

  int _failures = 0;
  DateTime? _notBefore;
  DateTime? _lastAttempt;
  DirectMailException? _lastError;
  bool _needsReauthentication = false;

  /// The account's credentials were refused; nothing is tried until
  /// [credentialsChanged].
  bool get needsReauthentication => _needsReauthentication;

  /// The earliest time an automatic attempt is allowed.
  DateTime? get nextAttemptAt => _notBefore;

  DirectMailException? get lastError => _lastError;
  int get consecutiveFailures => _failures;

  /// Whether the server may be contacted now. Throws the reason it may not.
  /// [userInitiated] (pull to refresh, opening a mail, sending) is allowed to
  /// shorten an ordinary back-off, never a refused sign-in or a rate limit.
  void checkAllowed({bool userInitiated = false}) {
    if (_needsReauthentication) {
      throw _lastError ?? DirectMailException(DirectErrorKind.authFailed);
    }
    final until = _notBefore;
    if (until == null) return;
    final now = _clock();
    if (!now.isBefore(until)) return;
    final last = _lastError;
    final hardPause = last?.kind == DirectErrorKind.rateLimited;
    final enoughSinceLast =
        _lastAttempt != null &&
        now.difference(_lastAttempt!) >= manualRetryAfter;
    if (userInitiated && !hardPause && enoughSinceLast) return;
    throw last ?? DirectMailException(DirectErrorKind.temporaryFailure);
  }

  /// Call right before an attempt to reach the server.
  void attempting() => _lastAttempt = _clock();

  void succeeded() {
    _failures = 0;
    _notBefore = null;
    _lastError = null;
  }

  void failed(DirectMailException error) {
    _lastError = error;
    switch (error.kind) {
      case DirectErrorKind.authFailed ||
          DirectErrorKind.authRequiresAppPassword ||
          DirectErrorKind.authMethodUnsupported:
        _needsReauthentication = true;
        _notBefore = null;
      case DirectErrorKind.offline:
        // The device, not the server: connectivity coming back is the cue to
        // try again, so no waiting period builds up.
        break;
      case DirectErrorKind.rateLimited:
        _failures++;
        _notBefore = _clock().add(rateLimitQuiet);
      case _ when _isConnectionLevel(error):
        _failures++;
        _notBefore = _clock().add(_backoff());
      default:
        // A refused command (no such folder, …) says nothing about whether
        // the server can be reached.
        break;
    }
  }

  /// The user fixed the password or the server settings.
  void credentialsChanged() {
    _needsReauthentication = false;
    _failures = 0;
    _notBefore = null;
    _lastError = null;
  }

  Duration _backoff() {
    final base = schedule[min(_failures - 1, schedule.length - 1)];
    final jitter = 0.8 + _random.nextDouble() * 0.4;
    return Duration(milliseconds: (base.inMilliseconds * jitter).round());
  }

  /// Failures that mean the connection or the server, not one command.
  static bool _isConnectionLevel(DirectMailException error) =>
      error.category == ApiErrorCategory.network ||
      error.category == ApiErrorCategory.timeout ||
      error.kind == DirectErrorKind.temporaryFailure ||
      error.kind == DirectErrorKind.tlsHandshakeFailed ||
      error.kind == DirectErrorKind.tlsCertificateInvalid;

  /// Whether the connection should be dropped after [error]: anything that
  /// leaves it in an unknown state.
  static bool breaksConnection(DirectMailException error) =>
      _isConnectionLevel(error) ||
      error.kind == DirectErrorKind.rateLimited ||
      error.category == ApiErrorCategory.authentication;
}
