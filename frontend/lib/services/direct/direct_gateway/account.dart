part of '../direct_mail_gateway.dart';

mixin _DirectAccountApi on _DirectGatewayBase {
  static const _signatureKey = 'signature';
  static const _notificationKey = 'notification_settings';

  Future<MailAccount> getAccount() async => _account();

  MailAccount _account() {
    final name = config.displayName.trim();
    return MailAccount(
      id: accountId,
      email: config.email,
      displayName: name.isEmpty ? null : name,
      provider: AccountProvider.inferFromEmail(config.email),
      status:
          connection.state == DirectConnectionState.needsReauthentication ||
              _smtpRefusal != null
          ? MailAccountStatus.needsReauthentication
          : MailAccountStatus.active,
      signature: store.setting(accountId, _signatureKey),
      mode: AccountMode.direct,
    );
  }

  /// Mailbox usage from the IMAP QUOTA extension; null when the server has
  /// none or cannot be asked right now (the figure is only a hint).
  Future<AccountQuota?> getQuota() async {
    try {
      final quota = await _run((imap) async {
        if (!imap.capabilities.quota) return null;
        return imap.quota();
      });
      return quota == null
          ? null
          : AccountQuota(
              usedBytes: quota.usedBytes,
              limitBytes: quota.limitBytes,
            );
    } on DirectMailException {
      return null;
    }
  }

  Future<void> updateSignature(String? signature) async {
    final text = signature?.trim() ?? '';
    store.putSetting(accountId, _signatureKey, text.isEmpty ? null : text);
  }

  /// Signs in again with a corrected password and, optionally, corrected
  /// server settings. The new values are kept only once the server accepted
  /// them; a refusal leaves the account waiting for the next correction.
  Future<MailAccount> reconnect({
    required String password,
    ManualMailServer? imap,
    ManualMailServer? smtp,
  }) async {
    final next = config.copyWith(
      imap: imap == null
          ? null
          : config.imap.copyWith(
              host: imap.host,
              port: imap.port,
              security: imap.security,
            ),
      smtp: smtp == null
          ? null
          : config.smtp.copyWith(
              host: smtp.host,
              port: smtp.port,
              security: smtp.security,
            ),
    );
    final problem = next.imap.problem ?? next.smtp.problem;
    if (password.isEmpty || problem != null) {
      throw DirectMailException(DirectErrorKind.authFailed);
    }
    await runtime.update(
      config: next,
      credentials: DirectCredentials(
        imapPassword: password,
        // A separate outgoing password stays as it is.
        smtpPassword: runtime.credentials.smtpPassword,
      ),
    );
    // One real sign-in decides: a refusal throws here and keeps the lock.
    await _run((_) async {}, userInitiated: true);
    _smtpRefusal = null;
    store.saveAccount(next);
    await runtime.persistCredentials();
    _emit(const GatewayEvent(GatewayEventKind.online));
    return _account();
  }

  /// Forgets the account on this device: its connection, its stored mail and
  /// its passwords. Nothing on the mail server is touched.
  Future<void> deleteAccount() async {
    await runtime.close();
    store.removeAccount(accountId);
    await runtime.onDeleted?.call();
  }

  Future<List<FolderSyncStatus>> getSyncStatus() async => [
    for (final folder in store.folders(accountId))
      if (folder.selectable)
        FolderSyncStatus(
          folderId: folder.folderId,
          folderName: folder.name,
          folderType: folder.role.wireName,
          backfillComplete: folder.backfillComplete,
          lastSuccessfulSyncAt: folder.lastSyncMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(folder.lastSyncMs!),
          lastFailureAt: folder.lastFailureMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(folder.lastFailureMs!),
          lastFailureCategory: folder.lastFailureCode,
          consecutiveFailures: folder.consecutiveFailures,
        ),
  ];

  /// Which folders this device keeps in step with the server. The scope name
  /// is derived from the folder flags so the two cannot disagree.
  Future<({String scope, Set<String> syncedFolderIds})> getSyncScope() async {
    final folders = [
      for (final f in store.folders(accountId))
        if (f.selectable) f,
    ];
    final synced = {
      for (final f in folders)
        if (f.syncEnabled) f.folderId,
    };
    final defaults = {
      for (final f in folders)
        if (f.role == FolderRole.inbox || f.role == FolderRole.sent) f.folderId,
    };
    final scope = synced.length == folders.length && folders.isNotEmpty
        ? 'AllFolders'
        : _sameSet(synced, defaults)
        ? 'InboxAndSent'
        : 'SelectedFolders';
    return (scope: scope, syncedFolderIds: synced);
  }

  Future<({String scope, Set<String> syncedFolderIds})> updateSyncScope(
    String scope, {
    List<String>? folderIds,
  }) async {
    final folders = [
      for (final f in store.folders(accountId))
        if (f.selectable) f,
    ];
    final wanted = switch (scope) {
      'AllFolders' => {for (final f in folders) f.folderId},
      'SelectedFolders' => {
        for (final f in folders)
          if ((folderIds ?? const []).contains(f.folderId)) f.folderId,
      },
      _ => {
        for (final f in folders)
          if (f.role == FolderRole.inbox || f.role == FolderRole.sent)
            f.folderId,
      },
    };
    store.transaction(() {
      for (final f in folders) {
        store.setFolderSyncEnabled(
          accountId,
          f.folderId,
          wanted.contains(f.folderId),
        );
      }
    });
    return getSyncScope();
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  Future<AccountNotificationSettings> getNotificationSettings() async {
    final raw = store.setting(accountId, _notificationKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        return AccountNotificationSettings(
          enabled: json['enabled'] as bool? ?? true,
          inboxOnly: json['inboxOnly'] as bool? ?? true,
          privacy: NotificationPrivacy.fromBackend(
            json['privacy'] as String? ?? 'Full',
          ),
        );
      } catch (_) {
        // Fall through to the defaults.
      }
    }
    // The text is on this device already, so previews are the user's choice.
    return const AccountNotificationSettings(
      enabled: true,
      inboxOnly: true,
      privacy: NotificationPrivacy.full,
    );
  }

  Future<AccountNotificationSettings> updateNotificationSettings(
    AccountNotificationSettings settings,
  ) async {
    store.putSetting(
      accountId,
      _notificationKey,
      jsonEncode(settings.toJson()),
    );
    return getNotificationSettings();
  }

  /// Direct accounts have no push registration: new mail is found by this
  /// device itself. A placeholder keeps device-wide registration flows that
  /// loop over every account working.
  Future<DeviceRegistration> registerDevice({
    required String token,
    required String platform,
    required String appVersion,
    required String locale,
  }) async => DeviceRegistration(
    id: 'local',
    platform: platform,
    appVersion: appVersion,
    locale: locale,
  );

  Future<void> unregisterDevice(String id) async {}
}
