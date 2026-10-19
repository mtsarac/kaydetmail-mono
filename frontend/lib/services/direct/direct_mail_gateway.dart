import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
import 'direct_store.dart';
import 'email_mapper.dart';
import 'imap_models.dart';
import 'imap_service.dart';
import 'mime_processor.dart';
import 'sync_engine.dart';

part 'direct_gateway/account.dart';
part 'direct_gateway/folders.dart';
part 'direct_gateway/mail.dart';
part 'direct_gateway/unsupported.dart';

/// Shared state of the gateway's endpoint groups.
abstract class _DirectGatewayBase {
  _DirectGatewayBase(
    this.runtime,
    this.store,
    this.syncOptions,
    this.staleAfter,
    DateTime Function()? clock,
  ) : _clock = clock ?? DateTime.now;

  final DirectAccountRuntime runtime;
  final DirectStore store;
  final SyncOptions syncOptions;

  /// How old a folder's last sync may be before opening it starts another in
  /// the background.
  final Duration staleAfter;
  final DateTime Function() _clock;

  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();

  Stream<GatewayEvent> get events => _events.stream;

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

  /// Starts a background pass over [folderId] unless one is running. The
  /// repository learns of changes through [events]; failures only update the
  /// reachability state.
  void _syncSoon(String folderId) {
    if (!_syncing.add(folderId)) return;
    unawaited(() async {
      try {
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
            ),
          );
        }
      } catch (_) {
        // Already recorded by _run / the engine.
      } finally {
        _syncing.remove(folderId);
      }
    }());
  }
}

/// The gateway of a direct account: the same contract the KaydetMail backend
/// answers, served from this device. Mail is read from the local store
/// (painted immediately, offline included) and kept current by syncing with
/// the mail server over IMAP; changes go to the server first.
class DirectMailGateway extends _DirectGatewayBase
    with
        _DirectUnsupportedApi,
        _DirectAccountApi,
        _DirectFolderApi,
        _DirectMailApi
    implements MailGateway {
  DirectMailGateway({
    required DirectAccountRuntime runtime,
    required DirectStore store,
    SyncOptions syncOptions = const SyncOptions(),
    Duration staleAfter = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : super(runtime, store, syncOptions, staleAfter, clock);

  /// Closes the connection and stops reporting.
  Future<void> dispose() async {
    await runtime.close();
    await _events.close();
  }
}
