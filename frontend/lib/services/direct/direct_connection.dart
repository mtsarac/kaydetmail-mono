import 'dart:async';

import 'connection_policy.dart';
import 'direct_errors.dart';
import 'imap_models.dart';
import 'imap_service.dart';

/// What the account's connection is doing, for status displays.
enum DirectConnectionState {
  idle,
  connecting,
  ready,
  waiting,
  needsReauthentication,
}

/// The one connection of one direct account.
///
/// * At most one connection, ever: operations queue and run one at a time,
///   so a sync, a flag change and a body fetch never open a second session
///   (servers with per-user connection limits cut off the surplus).
/// * Signing in happens once per connection; a refusal puts the account in
///   [DirectConnectionState.needsReauthentication] and nothing else is tried
///   until [credentialsChanged].
/// * The connection is closed after [idleClose] without work, unless it is
///   deliberately kept open to watch for new mail ([watch]).
/// * Whether the server may be contacted is decided by [ConnectionPolicy].
class DirectConnection {
  DirectConnection({
    required this._create,
    ConnectionPolicy? policy,
    this._isOnline,
    this.idleClose = const Duration(seconds: 60),
    this.onNeedsReauthentication,
    this.onRecovered,
  }) : policy = policy ?? ConnectionPolicy();

  final ImapService Function() _create;
  final ConnectionPolicy policy;
  final Future<bool> Function()? _isOnline;
  final Duration idleClose;

  /// Called once when the server refuses the credentials.
  final void Function()? onNeedsReauthentication;

  /// Called when a connection succeeds after the account needed
  /// reauthentication.
  final void Function()? onRecovered;

  ImapService? _imap;
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  Timer? _closeTimer;
  bool _closed = false;
  bool _awaitingRecovery = false;
  DirectConnectionState _state = DirectConnectionState.idle;

  // The watch the caller asked for, and the IDLE currently serving it.
  String? _watchFolder;
  StreamController<ImapPush>? _watchOut;
  StreamSubscription<ImapPush>? _idle;

  DirectConnectionState get state => policy.needsReauthentication
      ? DirectConnectionState.needsReauthentication
      : _state;

  /// Capabilities of the live connection, if any.
  ImapCapabilities? get capabilities =>
      (_imap?.isConnected ?? false) ? _imap!.capabilities : null;

  bool get isWatching => _idle != null;

  /// Runs [operation] on the connection, connecting first if needed.
  ///
  /// Throws the [DirectMailException] explaining why the server could not be
  /// used, without contacting it when the policy forbids an attempt.
  /// [userInitiated] work may shorten an ordinary waiting period.
  Future<T> run<T>(
    Future<T> Function(ImapService imap) operation, {
    bool userInitiated = false,
  }) => _enqueue(() => _runNow(operation, userInitiated));

  /// Puts [job] behind everything already waiting for the connection.
  Future<T> _enqueue<T>(Future<T> Function() job) {
    final completer = Completer<T>();
    final previous = _tail;
    _pending++;
    _tail = completer.future.then<void>((_) {}, onError: (_) {});
    previous.then((_) async {
      try {
        completer.complete(await job());
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _pending--;
      }
    });
    return completer.future;
  }

  Future<T> _runNow<T>(
    Future<T> Function(ImapService imap) operation,
    bool userInitiated,
  ) async {
    if (_closed) throw DirectMailException(DirectErrorKind.offline);
    _closeTimer?.cancel();
    await _pauseIdle();
    // Only a real attempt (a connection made, or work on a live one) can be a
    // failure worth waiting for. Being refused permission to try, or finding
    // the device offline, must not push the next attempt further away.
    var attempted = false;
    try {
      var imap = _imap;
      if (imap == null || !imap.isConnected) {
        policy.checkAllowed(userInitiated: userInitiated);
        if (_isOnline != null && !await _isOnline()) {
          throw DirectMailException(DirectErrorKind.offline);
        }
        attempted = true;
        imap = _imap = _create();
        _state = DirectConnectionState.connecting;
        policy.attempting();
        await imap.connect();
        policy.succeeded();
        if (_awaitingRecovery) {
          _awaitingRecovery = false;
          onRecovered?.call();
        }
      }
      attempted = true;
      final result = await operation(imap);
      _state = DirectConnectionState.ready;
      return result;
    } catch (error) {
      final mapped = DirectMailException.from(error);
      if (attempted) {
        final before = policy.needsReauthentication;
        policy.failed(mapped);
        if (!before && policy.needsReauthentication) {
          _awaitingRecovery = true;
          onNeedsReauthentication?.call();
        }
        _state = policy.needsReauthentication
            ? DirectConnectionState.needsReauthentication
            : policy.nextAttemptAt == null
            ? DirectConnectionState.idle
            : DirectConnectionState.waiting;
        if (ConnectionPolicy.breaksConnection(mapped) ||
            !(_imap?.isConnected ?? false)) {
          await _drop();
        }
      }
      if (identical(mapped, error)) rethrow;
      throw mapped;
    } finally {
      // Back to watching when nothing else is waiting for the connection.
      if (_pending <= 1) await _resumeIdle();
      _scheduleIdleClose();
    }
  }

  void _scheduleIdleClose() {
    _closeTimer?.cancel();
    if (_closed || _idle != null || _watchFolder != null || _imap == null) {
      return;
    }
    _closeTimer = Timer(idleClose, () {
      // Behind any work that arrived meanwhile, and only if still unused.
      unawaited(
        _enqueue<void>(() async {
          if (_pending <= 1 && _idle == null && _watchFolder == null) {
            await _drop();
          }
        }).catchError((_) {}),
      );
    });
  }

  Future<void> _drop() async {
    await _stopIdle();
    final imap = _imap;
    _imap = null;
    if (imap != null) await imap.disconnect();
    if (_state == DirectConnectionState.ready ||
        _state == DirectConnectionState.connecting) {
      _state = DirectConnectionState.idle;
    }
  }

  // --- Watching for new mail --------------------------------------------------------

  /// Keeps the connection open on [folderPath] and reports what the server
  /// pushes. Other work interrupts the wait and the watch resumes afterwards.
  /// An error ends the stream; the caller decides when to watch again (after
  /// the policy's waiting period). Cancelling the subscription stops it.
  Stream<ImapPush> watch(String folderPath) {
    final out = StreamController<ImapPush>(onCancel: _endWatch);
    _watchFolder = folderPath;
    _watchOut = out;
    // A no-op operation connects (if allowed) and starts the wait.
    run<void>((_) async {}).catchError((Object error) {
      if (!out.isClosed) out.addError(DirectMailException.from(error));
      _endWatch();
    });
    return out.stream;
  }

  Future<void> _resumeIdle() async {
    final folder = _watchFolder;
    final out = _watchOut;
    final imap = _imap;
    if (folder == null ||
        out == null ||
        out.isClosed ||
        _closed ||
        _idle != null ||
        imap == null ||
        !imap.isConnected ||
        !imap.capabilities.idle) {
      return;
    }
    _idle = imap
        .idle(folder)
        .listen(
          out.add,
          onError: (Object error) {
            if (!out.isClosed) out.addError(DirectMailException.from(error));
            _endWatch();
            unawaited(_drop());
          },
        );
  }

  Future<void> _pauseIdle() => _stopIdle();

  Future<void> _stopIdle() async {
    final sub = _idle;
    _idle = null;
    await sub?.cancel();
  }

  Future<void> _endWatch() async {
    final out = _watchOut;
    _watchFolder = null;
    _watchOut = null;
    await _stopIdle();
    if (out != null && !out.isClosed) await out.close();
    _scheduleIdleClose();
  }

  // --- Lifecycle ---------------------------------------------------------------------------

  /// The user corrected the password or server settings: allow attempts again
  /// and drop any connection made with the old ones.
  Future<void> credentialsChanged() async {
    policy.credentialsChanged();
    _state = DirectConnectionState.idle;
    await _drop();
  }

  /// Closes everything and refuses further work.
  Future<void> close() async {
    _closed = true;
    _closeTimer?.cancel();
    await _endWatch();
    await _drop();
  }
}
