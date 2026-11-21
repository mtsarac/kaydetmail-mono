import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/models/account_notification_settings.dart';
import 'package:kaydetmail/services/direct/direct_alerts.dart';
import 'package:kaydetmail/services/gateway/gateway_models.dart';

IncomingMail _mail(
  String id, {
  String folder = 'Inbox',
  String sender = 'Şirin',
  String subject = 'Toplantı',
  String preview = 'saat 10',
}) => IncomingMail(
  mailId: id,
  folderId: 'f1',
  folderType: folder,
  sender: sender,
  subject: subject,
  preview: preview,
);

AccountNotificationSettings _settings({
  bool enabled = true,
  bool inboxOnly = true,
  NotificationPrivacy privacy = NotificationPrivacy.full,
}) => AccountNotificationSettings(
  enabled: enabled,
  inboxOnly: inboxOnly,
  privacy: privacy,
);

void main() {
  test('full privacy shows sender, subject and a line of the text', () {
    final alerts = DirectMailAlerts.build(
      accountId: 'a',
      mail: [_mail('m1')],
      settings: _settings(),
    );
    expect(alerts.single.title, 'Şirin');
    expect(alerts.single.body, 'Toplantı\nsaat 10');
    expect(alerts.single.mailId, 'm1');
    expect(alerts.single.accountId, 'a');
  });

  test('limited privacy leaves the text out', () {
    final alerts = DirectMailAlerts.build(
      accountId: 'a',
      mail: [_mail('m1')],
      settings: _settings(privacy: NotificationPrivacy.limited),
    );
    expect(alerts.single.body, 'Toplantı');
  });

  test('private notifications say nothing about the mail', () {
    final alerts = DirectMailAlerts.build(
      accountId: 'a',
      mail: [_mail('m1')],
      settings: _settings(privacy: NotificationPrivacy.private),
    );
    expect(alerts.single.title, isNot(contains('Şirin')));
    expect(alerts.single.body, isNot(contains('Toplantı')));
    expect(alerts.single.mailId, 'm1', reason: 'a tap still opens the mail');
  });

  test('a mail without a subject or preview is still described', () {
    final alerts = DirectMailAlerts.build(
      accountId: 'a',
      mail: [_mail('m1', subject: '  ', preview: '')],
      settings: _settings(),
    );
    expect(alerts.single.body, isNotEmpty);
  });

  test(
    'turned off, or outside the Inbox when Inbox only, nothing is shown',
    () {
      expect(
        DirectMailAlerts.build(
          accountId: 'a',
          mail: [_mail('m1')],
          settings: _settings(enabled: false),
        ),
        isEmpty,
      );
      final mixed = DirectMailAlerts.build(
        accountId: 'a',
        mail: [
          _mail('m1'),
          _mail('m2', folder: 'Custom'),
        ],
        settings: _settings(),
      );
      expect(mixed.map((n) => n.mailId), ['m1']);
      final all = DirectMailAlerts.build(
        accountId: 'a',
        mail: [
          _mail('m1'),
          _mail('m2', folder: 'Custom'),
        ],
        settings: _settings(inboxOnly: false),
      );
      expect(all.map((n) => n.mailId), ['m1', 'm2']);
    },
  );

  test('every mail has its own notification id', () {
    final alerts = DirectMailAlerts.build(
      accountId: 'a',
      mail: [_mail('m1'), _mail('m2')],
      settings: _settings(),
    );
    expect(alerts.map((n) => n.id).toSet(), hasLength(2));
  });
}
