import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/l10n.dart';
import '../../models/account_notification_settings.dart';
import '../gateway/gateway_models.dart';
import '../mail_notifications.dart';

/// Turns mail that a direct account received into notifications, following
/// the account's own settings (on/off, Inbox only, how much to reveal).
class DirectMailAlerts {
  const DirectMailAlerts._();

  static List<MailNotification> build({
    required String accountId,
    required List<IncomingMail> mail,
    required AccountNotificationSettings settings,
  }) {
    if (!settings.enabled) return const [];
    return [
      for (final item in mail)
        if (!settings.inboxOnly || item.folderType == 'Inbox')
          _one(accountId, item, settings.privacy),
    ];
  }

  static MailNotification _one(
    String accountId,
    IncomingMail mail,
    NotificationPrivacy privacy,
  ) {
    final sender = mail.sender.trim();
    final subject = mail.subject.trim().isEmpty
        ? l10nNow.noSubject2
        : mail.subject.trim();
    if (privacy == NotificationPrivacy.private || sender.isEmpty) {
      return MailNotification(
        accountId: accountId,
        mailId: mail.mailId,
        title: l10nNow.newEmail2,
        body: l10nNow.youHaveANewMessage,
      );
    }
    final preview = mail.preview.trim();
    return MailNotification(
      accountId: accountId,
      mailId: mail.mailId,
      title: sender,
      body: privacy == NotificationPrivacy.full && preview.isNotEmpty
          ? '$subject\n$preview'
          : subject,
    );
  }
}

/// Shows notifications raised on this device. They carry no quick actions
/// (read, archive, delete): those run against the backend API, which a direct
/// account does not have.
class DirectMailNotificationDisplay implements MailNotificationDisplay {
  DirectMailNotificationDisplay(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> show(MailNotification notification, {String? notice}) {
    final body = notice == null
        ? notification.body
        : '$notice\n${notification.body}';
    return _plugin.show(
      id: notification.id,
      title: notification.title,
      body: body,
      notificationDetails: MailNotifications.details(body, withActions: false),
      payload: notification.payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
