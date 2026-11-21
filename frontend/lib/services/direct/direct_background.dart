import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../state/app_settings_controller.dart';
import '../mail_cache.dart';
import '../mail_notifications.dart';
import '../notification_settings_store.dart';
import '../session_store.dart';
import 'direct_account_service.dart';
import 'direct_alerts.dart';
import 'direct_store.dart';

/// Checks direct accounts for new mail while the app is closed.
///
/// A direct account has no server to push to the phone, so the system wakes
/// the app instead: Android's WorkManager runs [directBackgroundDispatcher]
/// about every 15 minutes (the shortest period it allows, and the system may
/// delay it further in Doze) while the device is online. Each run signs in to
/// every direct account, sends scheduled mail that is due, pulls the Inbox
/// within a time budget and shows a notification for what arrived.
///
/// iOS is not covered: it needs `BGAppRefreshTask` entries in `Info.plist`
/// and the AppDelegate, which this repository does not set up yet.
class DirectBackground {
  const DirectBackground._();

  static const _uniqueName = 'kaydet.direct.mailcheck';
  static const _taskName = 'directMailCheck';

  /// When the app last said it is in front (ms since epoch), 0 when it is not.
  /// The worker stays out of the way of a running app, which watches the
  /// Inbox itself and must not announce mail the user is looking at.
  static const _activeKey = 'kaydet.app.active_ms';
  static const _heartbeat = Duration(minutes: 4);
  static const _staleAfter = Duration(minutes: 10);

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Timer? _heartbeatTimer;

  /// Schedules the periodic check when a direct account exists and removes it
  /// when none is left. Safe to call whenever accounts change; never throws.
  static Future<void> sync() async {
    if (!isSupported) return;
    try {
      final manager = Workmanager();
      if ((await SessionStore.loadDirectAccounts()).isEmpty) {
        await manager.cancelByUniqueName(_uniqueName);
        return;
      }
      await manager.initialize(directBackgroundDispatcher);
      await manager.registerPeriodicTask(
        _uniqueName,
        _taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (error) {
      debugPrint('DirectBackground: not scheduled ($error).');
    }
  }

  /// Records whether the app is in front, so the worker knows to wait.
  static void markForeground(bool active, {required bool hasDirectAccount}) {
    if (!isSupported || !hasDirectAccount) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    unawaited(_stamp(active));
    if (active) {
      _heartbeatTimer = Timer.periodic(
        _heartbeat,
        (_) => unawaited(_stamp(true)),
      );
    }
  }

  static Future<void> _stamp(bool active) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _activeKey,
        active ? DateTime.now().millisecondsSinceEpoch : 0,
      );
    } catch (_) {
      // Without the stamp the worker may run beside a live app; harmless.
    }
  }

  /// One background pass over every direct account. Failures of one account
  /// never stop the others.
  @visibleForTesting
  static Future<void> runCheck() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final since = prefs.getInt(_activeKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (since != 0 && now - since < _staleAfter.inMilliseconds) return;

    final entries = await SessionStore.loadDirectAccounts();
    if (entries.isEmpty) return;
    await AppSettingsController.instance.loadLanguage();
    final notify = await NotificationSettingsStore.load();

    final plugin = FlutterLocalNotificationsPlugin();
    await MailNotifications.initialize(plugin);
    final display = DirectMailNotificationDisplay(plugin);
    final store = DirectStore((await MailCache.open()).db);
    final accounts = DirectAccountService();

    for (final entry in entries) {
      final gateway = await accounts.restore(entry.id, store);
      if (gateway == null) continue;
      try {
        final incoming = await gateway.checkForMail();
        if (!notify || incoming.isEmpty) continue;
        final alerts = DirectMailAlerts.build(
          accountId: entry.id,
          mail: incoming,
          settings: await gateway.getNotificationSettings(),
        );
        for (final alert in alerts) {
          await display.show(alert);
        }
      } catch (error) {
        debugPrint('DirectBackground: ${entry.email} skipped ($error).');
      } finally {
        await gateway.dispose();
      }
    }
  }
}

/// Entry point WorkManager starts in a fresh isolate.
@pragma('vm:entry-point')
void directBackgroundDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    try {
      await DirectBackground.runCheck();
    } catch (error) {
      debugPrint('DirectBackground: run failed ($error).');
    }
    // A periodic task is rescheduled whatever this returns; retrying a
    // refused sign-in is what gets an address blocked.
    return true;
  });
}
