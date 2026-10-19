part of '../direct_mail_gateway.dart';

/// Keeping an eye on the Inbox while the app is open.
///
/// A server that supports IDLE tells the app the moment mail arrives; one
/// that does not is asked every minute and a half. Either way a slow
/// safety check runs too, because a connection can go quiet without saying
/// so. When the app goes to the background the watch ends and the
/// connection is closed after its idle period; nothing keeps running for an
/// app the system has stopped, which is why direct accounts raise no
/// notifications while the app is closed (see the capabilities).
mixin _DirectWatchApi
    on
        _DirectGatewayBase,
        _DirectMailApi,
        _DirectActionApi,
        _DirectComposeApi,
        _DirectScheduledApi {
  bool _foreground = false;
  int _watchGeneration = 0;
  StreamSubscription<ImapPush>? _watchSub;
  Timer? _pollTimer;
  Timer? _restartTimer;
  Timer? _pushDebounce;

  /// How long to wait before watching again after the watch broke.
  static const _restartAfter = Duration(seconds: 30);
  static const _pollWithIdle = Duration(minutes: 5);
  static const _pollWithoutIdle = Duration(seconds: 90);
  static const _pushDebounceFor = Duration(milliseconds: 400);

  Timer? _graceTimer;

  /// In front: watch the Inbox. Away: keep watching for [backgroundGrace]
  /// (the process often lives a while after the user leaves, and mail that
  /// arrives then is worth a notification), then let go.
  void setForeground(bool foreground) {
    _graceTimer?.cancel();
    _graceTimer = null;
    if (foreground) {
      final alreadyWatching = _foreground;
      _foreground = true;
      unawaited(runDueScheduledSends().catchError((Object _) => 0));
      if (!alreadyWatching || !isWatching) unawaited(_startWatching());
      return;
    }
    if (!_foreground) return;
    _graceTimer = Timer(backgroundGrace, () {
      _foreground = false;
      _stopWatching();
    });
  }

  bool get isWatching => _watchSub != null || _pollTimer != null;

  Future<void> _startWatching() async {
    _stopWatching(keepForeground: true);
    final generation = ++_watchGeneration;
    try {
      if (store.folders(accountId).isEmpty) {
        await _refreshFolderList();
      }
      final inbox = store.folderByRole(accountId, FolderRole.inbox);
      if (inbox == null || !inbox.selectable) return;
      final idle = await _run((imap) async => imap.capabilities.idle);
      if (generation != _watchGeneration || !_foreground) return;

      if (idle) {
        _watchSub = connection
            .watch(inbox.path)
            .listen(
              (_) {
                // Several pushes in a burst are one pass.
                _pushDebounce?.cancel();
                _pushDebounce = Timer(_pushDebounceFor, () {
                  if (_foreground) _syncSoon(inbox.folderId);
                });
              },
              onError: (Object error) {
                _noteFailure(DirectMailException.from(error));
                _restartLater(generation);
              },
              onDone: () => _restartLater(generation),
            );
      }
      _pollTimer = Timer.periodic(
        idle ? _pollWithIdle : _pollWithoutIdle,
        (_) => _syncSoon(inbox.folderId),
      );
      // Anything that arrived before the watch began.
      _syncSoon(inbox.folderId);
    } on DirectMailException {
      _restartLater(generation);
    }
  }

  void _restartLater(int generation) {
    if (generation != _watchGeneration || !_foreground) return;
    _stopWatching(keepForeground: true);
    _restartTimer = Timer(_restartAfter, () {
      if (_foreground) unawaited(_startWatching());
    });
  }

  void _stopWatching({bool keepForeground = false}) {
    if (!keepForeground) _watchGeneration++;
    _restartTimer?.cancel();
    _pushDebounce?.cancel();
    _pollTimer?.cancel();
    unawaited(_watchSub?.cancel());
    _restartTimer = _pushDebounce = _pollTimer = null;
    _watchSub = null;
  }
}
