import 'package:flutter/foundation.dart';

/// How one account reaches its mail server. Chosen when the account is
/// added and never changes: switching means removing and re-adding it.
enum AccountMode {
  /// Through the KaydetMail backend (HTTP API, push, server-side sync).
  backend,

  /// Straight from this device over IMAP/SMTP, with a local mail store.
  direct;

  /// Stable value persisted in the account registry.
  String get storageValue => name;

  static AccountMode fromStorage(String? value) =>
      value == 'direct' ? AccountMode.direct : AccountMode.backend;
}

/// What an account can do. Screens ask this instead of checking the mode, so
/// a difference between the two connection kinds is always an explicit,
/// named capability rather than a silent special case.
@immutable
class AccountCapabilities {
  const AccountCapabilities({
    required this.mode,
    required this.deviceSessions,
    required this.serverPush,
    required this.guaranteedScheduledSend,
    required this.serverSyncStatus,
    required this.crossDeviceMetadata,
    required this.serverSideSearch,
    required this.backgroundPolling,
  });

  /// KaydetMail backend account: everything the API offers.
  const AccountCapabilities.backend()
    : mode = AccountMode.backend,
      deviceSessions = true,
      serverPush = true,
      guaranteedScheduledSend = true,
      serverSyncStatus = true,
      crossDeviceMetadata = true,
      serverSideSearch = true,
      backgroundPolling = false;

  /// Direct IMAP/SMTP account. Server-side search and background polling are
  /// refined per account once the mail server's capabilities are known.
  const AccountCapabilities.direct({
    this.serverSideSearch = true,
    this.backgroundPolling = true,
  }) : mode = AccountMode.direct,
       deviceSessions = false,
       serverPush = false,
       guaranteedScheduledSend = false,
       serverSyncStatus = false,
       crossDeviceMetadata = false;

  final AccountMode mode;

  /// Per-device login sessions can be listed and revoked.
  final bool deviceSessions;

  /// New mail is announced by a server push (FCM) rather than by this device
  /// polling.
  final bool serverPush;

  /// A scheduled send fires on time even when this device is off.
  final bool guaranteedScheduledSend;

  /// A server-side sync status screen exists.
  final bool serverSyncStatus;

  /// Pins, labels, snoozes, templates, … follow the account to other devices.
  final bool crossDeviceMetadata;

  /// The mail server can search its own mailbox.
  final bool serverSideSearch;

  /// This device checks the mailbox itself in the background (best effort,
  /// as far as the OS allows).
  final bool backgroundPolling;

  bool get isDirect => mode == AccountMode.direct;

  AccountCapabilities copyWith({
    bool? serverSideSearch,
    bool? backgroundPolling,
  }) => AccountCapabilities(
    mode: mode,
    deviceSessions: deviceSessions,
    serverPush: serverPush,
    guaranteedScheduledSend: guaranteedScheduledSend,
    serverSyncStatus: serverSyncStatus,
    crossDeviceMetadata: crossDeviceMetadata,
    serverSideSearch: serverSideSearch ?? this.serverSideSearch,
    backgroundPolling: backgroundPolling ?? this.backgroundPolling,
  );
}
