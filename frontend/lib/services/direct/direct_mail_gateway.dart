import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:enough_mail_plus/enough_mail.dart' show DateCodec, MimeMessage;
import 'package:http/http.dart' as http;

import '../../models/account_capabilities.dart';
import '../../models/account_notification_settings.dart';
import '../../models/compose_limits.dart';
import '../../models/compose_prefill.dart';
import '../../models/email.dart';
import '../../models/folder_sync_status.dart';
import '../../models/mail_account.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_header_entry.dart';
import '../../models/mail_security.dart';
import '../../models/mail_session.dart';
import '../../models/mail_signature.dart';
import '../../models/mail_template.dart';
import '../../models/remote_search_result.dart';
import '../../models/scheduled_send.dart';
import '../../models/scheduled_send_detail.dart';
import '../../models/trusted_sender.dart';
import '../api_auth_service.dart' show ManualMailServer;
import '../api_exception.dart';
import '../gateway/gateway_models.dart';
import '../gateway/mail_gateway.dart';
import 'connection_policy.dart';
import 'direct_account_runtime.dart';
import 'direct_account_setup.dart';
import 'direct_connection.dart';
import 'direct_credential_store.dart';
import 'direct_errors.dart';
import 'direct_scheduled_store.dart';
import 'direct_send_journal.dart';
import 'direct_meta_store.dart';
import 'direct_store.dart';
import 'email_mapper.dart';
import 'imap_flags.dart';
import 'imap_models.dart';
import 'imap_service.dart';
import 'mail_recipients.dart';
import 'mail_threading.dart';
import 'message_composer.dart';
import 'mime_processor.dart';
import 'sync_engine.dart';

part 'direct_gateway/account.dart';
part 'direct_gateway/actions.dart';
part 'direct_gateway/compose.dart';
part 'direct_gateway/folders.dart';
part 'direct_gateway/local.dart';
part 'direct_gateway/mail.dart';
part 'direct_gateway/scheduled.dart';
part 'direct_gateway/search.dart';
part 'direct_gateway/watch.dart';
part 'direct_gateway/sessions.dart';

/// Shared state of the gateway's endpoint groups.
abstract class _DirectGatewayBase {
  _DirectGatewayBase(
    this.runtime,
    this.store,
    this.syncOptions,
    this.staleAfter,
    this.schedulerTick,
    this.backgroundGrace,
    DateTime Function()? clock,
  ) : _clock = clock ?? DateTime.now;

  final DirectAccountRuntime runtime;
  final DirectStore store;
  final SyncOptions syncOptions;

  /// How old a folder's last sync may be before opening it starts another in
  /// the background.
  final Duration staleAfter;
  final DateTime Function() _clock;

  /// Longest the scheduled-send timer sleeps; null turns it off (tests drive
  /// [DirectMailGateway.runDueScheduledSends] themselves).
  final Duration? schedulerTick;
  Timer? _schedulerTimer;

  /// How long the Inbox is still watched after the app left the front.
  final Duration backgroundGrace;

  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();

  Stream<GatewayEvent> get events => _events.stream;

  /// The outgoing server refused the account's password. Sending stays off
  /// until the user supplies a new one ([reconnect]), because repeating a
  /// refused sign-in is what gets an address blocked.
  DirectMailException? _smtpRefusal;

  String get accountId => runtime.accountId;
  DirectAccountConfig get config => runtime.config;
  DirectConnection get connection => runtime.connection;

  void _emit(GatewayEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  // --- Reachability -------------------------------------------------------------

  /// The connectivity failure the last attempt ended with, until something
  /// succeeds. While set, [getFolders] probes the server instead of answering
  /// from the store, which is how the repository learns the server is back.
  DirectMailException? _unreachable;

  void _noteSuccess() {
    if (_unreachable != null) {
      _unreachable = null;
      _emit(const GatewayEvent(GatewayEventKind.online));
    }
  }

  void _noteFailure(DirectMailException error) {
    if (error.category == ApiErrorCategory.authentication) {
      _emit(const GatewayEvent(GatewayEventKind.needsReauthentication));
      return;
    }
    if (ConnectionPolicy.breaksConnection(error)) {
      final first = _unreachable == null;
      _unreachable = error;
      if (first) _emit(const GatewayEvent(GatewayEventKind.offline));
    }
  }

  /// Runs [operation] on the account's connection and keeps the reachability
  /// bookkeeping.
  Future<T> _run<T>(
    Future<T> Function(ImapService imap) operation, {
    bool userInitiated = false,
  }) async {
    try {
      final result = await connection.run(
        operation,
        userInitiated: userInitiated,
      );
      _noteSuccess();
      return result;
    } catch (error) {
      final mapped = DirectMailException.from(error);
      _noteFailure(mapped);
      if (identical(mapped, error)) rethrow;
      throw mapped;
    }
  }

  Future<T> _withEngine<T>(
    Future<T> Function(SyncEngine engine, ImapService imap) operation, {
    bool userInitiated = false,
  }) => _run(
    (imap) => operation(
      SyncEngine(
        store: store,
        imap: imap,
        accountId: accountId,
        ownAddress: config.email,
        options: syncOptions,
      ),
      imap,
    ),
    userInitiated: userInitiated,
  );

  // --- Lookups -----------------------------------------------------------------------

  MessageRow _requireMessage(String id) {
    final row = store.message(accountId, id);
    if (row == null) throw DirectMailException(DirectErrorKind.mailNotFound);
    return row;
  }

  FolderRow _requireFolder(String id) {
    final folder = store.folder(accountId, id);
    if (folder == null) {
      throw DirectMailException(DirectErrorKind.folderNotFound);
    }
    return folder;
  }

  DateTime? _folderListSyncedAt;

  /// Re-reads the server's folder list into the store.
  Future<void> _refreshFolderList({bool userInitiated = false}) async {
    await _withEngine(
      (engine, _) => engine.syncFolderList(),
      userInitiated: userInitiated,
    );
    _folderListSyncedAt = _clock();
  }

  // --- Sync ------------------------------------------------------------------------------

  final Set<String> _syncing = {};

  bool _isStale(FolderRow folder) {
    final last = folder.lastSyncMs;
    return last == null ||
        _clock().millisecondsSinceEpoch - last > staleAfter.inMilliseconds;
  }

  /// Brings [folderId] up to date and completes when it is. A pass that stops
  /// early (time, per-pass cap) is followed by another, a few times.
  Future<FolderSyncReport> _syncFolderNow(
    String folderId, {
    bool userInitiated = false,
    bool full = false,
  }) async {
    final total = FolderSyncReport();
    for (var pass = 0; pass < 5; pass++) {
      final report = await _withEngine(
        (engine, _) => engine.syncFolder(folderId, full: full && pass == 0),
        userInitiated: userInitiated,
      );
      total.newLocalIds.addAll(report.newLocalIds);
      total
        ..flagChanges += report.flagChanges
        ..removed += report.removed
        ..uidValidityChanged =
            total.uidValidityChanged || report.uidValidityChanged
        ..remoteExists = report.remoteExists;
      if (!report.stoppedEarly) break;
      total.stoppedEarly = true;
    }
    return total;
  }

  /// Folders that changed on the server while a pass over them was running;
  /// they get another pass when it ends, so nothing a push announced is lost.
  final Set<String> _syncAgain = {};

  /// Starts a background pass over [folderId] unless one is running (then
  /// one more follows it). The repository learns of changes through
  /// [events]; failures only update the reachability state.
  void _syncSoon(String folderId) {
    if (!_syncing.add(folderId)) {
      _syncAgain.add(folderId);
      return;
    }
    unawaited(() async {
      try {
        do {
          _syncAgain.remove(folderId);
          final wasSynced =
              store.folder(accountId, folderId)?.lastSyncMs != null;
          final report = await _syncFolderNow(folderId);
          if (report.newLocalIds.isNotEmpty ||
              report.flagChanges > 0 ||
              report.removed > 0 ||
              report.uidValidityChanged) {
            _emit(
              GatewayEvent(
                GatewayEventKind.mail,
                folderId: folderId,
                newMailIds: report.newLocalIds,
                // The first pass over a folder brings in old mail, not news.
                incoming: wasSynced ? _describe(report.newLocalIds) : const [],
              ),
            );
          }
        } while (_syncAgain.contains(folderId));
      } catch (_) {
        // Already recorded by _run / the engine.
      } finally {
        _syncing.remove(folderId);
        _syncAgain.remove(folderId);
      }
    }());
  }

  /// Unread, recent mail among [localIds], described for a notification.
  List<IncomingMail> _describe(List<String> localIds) {
    final cutoff = _clock()
        .subtract(const Duration(days: 2))
        .millisecondsSinceEpoch;
    final out = <IncomingMail>[];
    for (final id in localIds) {
      final row = store.message(accountId, id);
      if (row == null || row.isRead || row.sortMs < cutoff) continue;
      final folder = store.folder(accountId, row.folderId);
      if (folder == null) continue;
      out.add(
        IncomingMail(
          mailId: id,
          folderId: row.folderId,
          folderType: folder.role.wireName,
          sender: row.fromName.isNotEmpty ? row.fromName : row.fromAddress,
          subject: row.subject,
          preview: row.snippet,
        ),
      );
      if (out.length == 5) break;
    }
    return out;
  }
}

/// The gateway of a direct account: the same contract the KaydetMail backend
/// answers, served from this device. Mail is read from the local store
/// (painted immediately, offline included) and kept current by syncing with
/// the mail server over IMAP; changes go to the server first.
class DirectMailGateway extends _DirectGatewayBase
    with
        _DirectSessionsApi,
        _DirectAccountApi,
        _DirectFolderApi,
        _DirectMailApi,
        _DirectActionApi,
        _DirectLocalApi,
        _DirectComposeApi,
        _DirectScheduledApi,
        _DirectSearchApi,
        _DirectWatchApi
    implements MailGateway {
  DirectMailGateway({
    required DirectAccountRuntime runtime,
    required DirectStore store,
    SyncOptions syncOptions = const SyncOptions(),
    Duration staleAfter = const Duration(seconds: 30),
    Duration? schedulerTick = const Duration(minutes: 5),
    Duration backgroundGrace = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : super(
         runtime,
         store,
         syncOptions,
         staleAfter,
         schedulerTick,
         backgroundGrace,
         clock,
       ) {
    // A send that came due while the app was closed goes out now.
    _armScheduler();
  }

  /// Closes the connection and stops reporting.
  Future<void> dispose() async {
    _schedulerTimer?.cancel();
    _graceTimer?.cancel();
    _stopWatching();
    await runtime.close();
    await _events.close();
  }
}
