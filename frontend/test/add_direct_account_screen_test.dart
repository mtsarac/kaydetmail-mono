import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/config/app_config.dart';
import 'package:kaydetmail/models/account_capabilities.dart';
import 'package:kaydetmail/models/mail_account.dart';
import 'package:kaydetmail/repositories/mail_repository.dart';
import 'package:kaydetmail/screens/add_account_screen.dart';
import 'package:kaydetmail/screens/add_direct_account_screen.dart';
import 'package:kaydetmail/screens/settings/account_settings_screen.dart';
import 'package:kaydetmail/services/api_auth_service.dart' show MailSecurity;
import 'package:kaydetmail/services/direct/direct_account_setup.dart';
import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/settings_discovery.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo extends MailRepository {
  DirectAccountSetup? connectedWith;
  Object? failWith;
  final List<MailAccount> connected = [];

  @override
  List<MailAccount> get accounts => connected;

  @override
  MailAccount? getAccount(String accountId) =>
      connected.where((a) => a.id == accountId).firstOrNull;

  @override
  AccountCapabilities capabilitiesOf(String accountId) =>
      getAccount(accountId)?.isDirect == true
      ? const AccountCapabilities.direct()
      : const AccountCapabilities.backend();

  @override
  Future<DiscoveredSettings?> discoverDirectSettings(String email) async =>
      SettingsDiscovery.knownProvider(email) ?? SettingsDiscovery.guess(email);

  @override
  Future<MailAccount> connectDirectAccount(DirectAccountSetup setup) async {
    connectedWith = setup;
    if (failWith != null) throw failWith!;
    final account = MailAccount(
      id: 'd1',
      email: setup.email,
      displayName: setup.displayName,
      mode: AccountMode.direct,
    );
    connected.add(account);
    return account;
  }

  @override
  bool get isLoggedIn => connected.isNotEmpty;

  @override
  Future<void> refreshQuota(String accountId) async {}

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late _Repo repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppConfig.resetForTest();
    repo = _Repo();
    AppConfig.mailRepositoryForTest = repo;
  });

  /// Opens the screen from a button, so its result can be read.
  Future<MailAccount?> Function() mount(WidgetTester tester) {
    MailAccount? result;
    var done = false;
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () async {
                  result = await Navigator.of(context).push<MailAccount>(
                    MaterialPageRoute(
                      builder: (_) => const AddDirectAccountScreen(),
                    ),
                  );
                  done = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      return done ? result : null;
    };
  }

  Future<void> typeEmail(WidgetTester tester, String email) async {
    await tester.enterText(find.byKey(const Key('direct-email-field')), email);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a known provider fills the servers and warns about app passwords',
    (tester) async {
      await mount(tester)();
      await typeEmail(tester, 'ayse@gmail.com');
      expect(find.byKey(const Key('direct-app-password-note')), findsOneWidget);
      await tester.tap(find.text('Sunucu ayarları'));
      await tester.pumpAndSettle();
      final host = tester.widget<TextFormField>(
        find.byKey(const Key('direct-imap-host')),
      );
      expect(host.controller!.text, 'imap.gmail.com');
      final smtp = tester.widget<TextFormField>(
        find.byKey(const Key('direct-smtp-host')),
      );
      expect(smtp.controller!.text, 'smtp.gmail.com');
    },
  );

  testWidgets('an unknown domain is guessed, shown for checking', (
    tester,
  ) async {
    await mount(tester)();
    await typeEmail(tester, 'info@kucukfirma.com.tr');
    expect(
      find.text('Sunucu adlarını tahmin ettik. Bağlanmadan önce kontrol edin.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('direct-imap-host')),
      findsOneWidget,
      reason: 'the panel is open',
    );
    expect(find.byKey(const Key('direct-app-password-note')), findsNothing);
  });

  testWidgets('connecting sends what was entered and returns the account', (
    tester,
  ) async {
    final open = mount(tester);
    await open();
    await typeEmail(tester, 'ayse@kucukfirma.com.tr');
    await tester.enterText(
      find.byKey(const Key('direct-password-field')),
      'gizli',
    );
    await tester.enterText(
      find.byKey(const Key('direct-imap-host')),
      'mail.sunucum.example',
    );
    await tester.enterText(find.byKey(const Key('direct-imap-user')), 'ayse');
    await tester.tap(find.byKey(const Key('direct-connect-button')));
    await tester.pumpAndSettle();

    final setup = repo.connectedWith!;
    expect(setup.email, 'ayse@kucukfirma.com.tr');
    expect(setup.password, 'gizli');
    expect(setup.imap.host, 'mail.sunucum.example');
    expect(setup.imap.port, 993);
    expect(setup.imap.security, MailSecurity.sslOnConnect);
    expect(setup.imap.username, 'ayse');
    expect(
      setup.smtp.host,
      'mail.kucukfirma.com.tr',
      reason: 'the guess for the other server is kept',
    );
    expect(
      setup.displayName,
      'ayse',
      reason: 'defaults to the part before the @',
    );
    expect(setup.smtpPassword, isNull);
    expect(
      find.byKey(const Key('direct-connect-button')),
      findsNothing,
      reason: 'the screen closed',
    );
  });

  testWidgets('a separate outgoing password is passed on', (tester) async {
    await mount(tester)();
    await typeEmail(tester, 'ayse@gmail.com');
    await tester.enterText(
      find.byKey(const Key('direct-password-field')),
      'gizli',
    );
    await tester.tap(find.text('Sunucu ayarları'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('direct-separate-smtp-password')),
    );
    await tester.tap(find.byKey(const Key('direct-separate-smtp-password')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('direct-smtp-password')),
      'baska',
    );
    await tester.ensureVisible(find.byKey(const Key('direct-connect-button')));
    await tester.tap(find.byKey(const Key('direct-connect-button')));
    await tester.pumpAndSettle();
    expect(repo.connectedWith!.smtpPassword, 'baska');
  });

  testWidgets('a refused password is explained and the screen stays', (
    tester,
  ) async {
    repo.failWith = DirectMailException(DirectErrorKind.authFailed);
    await mount(tester)();
    await typeEmail(tester, 'ayse@gmail.com');
    await tester.enterText(
      find.byKey(const Key('direct-password-field')),
      'yanlis',
    );
    await tester.tap(find.byKey(const Key('direct-connect-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct-error')), findsOneWidget);
    expect(
      find.text('Kullanıcı adı veya şifre kabul edilmedi.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('direct-connect-button')), findsOneWidget);
  });

  testWidgets('a certificate for another name offers that name', (
    tester,
  ) async {
    repo.failWith = DirectMailException(
      DirectErrorKind.tlsCertificateInvalid,
      suggestedHost: 'mail.hosting.example',
      endpoint: 'imap',
    );
    await mount(tester)();
    await typeEmail(tester, 'ayse@kucukfirma.com.tr');
    await tester.enterText(
      find.byKey(const Key('direct-password-field')),
      'gizli',
    );
    await tester.tap(find.byKey(const Key('direct-connect-button')));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('direct-use-suggested-host'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final host = tester.widget<TextFormField>(
      find.byKey(const Key('direct-imap-host')),
    );
    expect(host.controller!.text, 'mail.hosting.example');
    expect(find.byKey(const Key('direct-error')), findsNothing);
  });

  testWidgets('bad server names and ports are caught before connecting', (
    tester,
  ) async {
    await mount(tester)();
    await typeEmail(tester, 'ayse@kucukfirma.com.tr');
    await tester.enterText(
      find.byKey(const Key('direct-password-field')),
      'gizli',
    );
    await tester.enterText(
      find.byKey(const Key('direct-imap-host')),
      'bad host/',
    );
    await tester.enterText(find.byKey(const Key('direct-imap-port')), '99999');
    await tester.tap(find.byKey(const Key('direct-connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('Geçerli bir sunucu adı girin'), findsOneWidget);
    expect(find.text('1 ile 65535 arasında bir değer girin'), findsOneWidget);
    expect(repo.connectedWith, isNull);
  });

  testWidgets('changing the security moves the usual port along', (
    tester,
  ) async {
    await mount(tester)();
    await typeEmail(tester, 'ayse@kucukfirma.com.tr');
    await tester.tap(find.byKey(const Key('direct-imap-security')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STARTTLS').last);
    await tester.pumpAndSettle();
    final port = tester.widget<TextFormField>(
      find.byKey(const Key('direct-imap-port')),
    );
    expect(port.controller!.text, '143');
  });

  testWidgets(
    'the add-account screen offers the direct way and returns to it',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AddAccountScreen()));
      expect(find.byKey(const Key('connect-directly')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('connect-directly')));
      await tester.tap(find.byKey(const Key('connect-directly')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('direct-email-field')), findsOneWidget);
      expect(find.byKey(const Key('direct-info-card')), findsOneWidget);
    },
  );

  testWidgets('a direct account shows its limits and no signed-in devices', (
    tester,
  ) async {
    repo.connected.add(
      const MailAccount(
        id: 'd1',
        email: 'ayse@example.test',
        mode: AccountMode.direct,
      ),
    );
    repo.connected.add(const MailAccount(id: 'b1', email: 'ben@example.test'));
    await tester.pumpWidget(
      const MaterialApp(home: AccountSettingsScreen(accountId: 'd1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct-account-note')), findsOneWidget);
    expect(find.text('Bağlı cihazlar', skipOffstage: false), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(home: AccountSettingsScreen(accountId: 'b1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct-account-note')), findsNothing);
    expect(find.text('Bağlı cihazlar', skipOffstage: false), findsOneWidget);
  });
}
