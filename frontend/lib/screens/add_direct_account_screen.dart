import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config/app_config.dart';
import '../l10n/l10n.dart';
import '../models/mail_account.dart';
import '../services/api_auth_service.dart' show MailSecurity;
import '../services/api_exception.dart';
import '../services/direct/direct_account_setup.dart';
import '../services/direct/direct_errors.dart';
import '../services/direct/settings_discovery.dart';
import '../services/push_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_messages.dart';

/// Connects a mailbox straight to its IMAP/SMTP servers, without the
/// KaydetMail backend. Asks for the address and password, fills in the
/// server settings by itself where it can (and says how sure it is), and
/// lets the user correct them. Pops with the connected [MailAccount].
class AddDirectAccountScreen extends StatefulWidget {
  const AddDirectAccountScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  State<AddDirectAccountScreen> createState() => _AddDirectAccountScreenState();
}

class _AddDirectAccountScreenState extends State<AddDirectAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _imapUser = TextEditingController();
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');
  final _smtpUser = TextEditingController();
  final _smtpPassword = TextEditingController();

  var _imapSecurity = MailSecurity.sslOnConnect;
  var _smtpSecurity = MailSecurity.sslOnConnect;
  var _showServers = false;
  var _serversEdited = false;
  var _separateSmtpPassword = false;
  var _obscure = true;
  var _busy = false;
  DiscoveredSettings? _discovered;
  String? _error;
  ({String host, String which})? _suggestion;
  Timer? _debounce;
  var _autofillFinished = false;

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void initState() {
    super.initState();
    _email.text = widget.initialEmail;
    _email.addListener(_onEmailChanged);
    if (_emailPattern.hasMatch(widget.initialEmail.trim())) {
      unawaited(_discover());
    }
  }

  @override
  void dispose() {
    if (!_autofillFinished) {
      TextInput.finishAutofillContext(shouldSave: false);
    }
    _debounce?.cancel();
    for (final c in [
      _email,
      _name,
      _password,
      _imapHost,
      _imapPort,
      _imapUser,
      _smtpHost,
      _smtpPort,
      _smtpUser,
      _smtpPassword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onEmailChanged() {
    _debounce?.cancel();
    final text = _email.text.trim();
    if (!_emailPattern.hasMatch(text)) return;
    _debounce = Timer(const Duration(milliseconds: 700), _discover);
  }

  Future<void> _discover() async {
    final email = _email.text.trim();
    if (!_emailPattern.hasMatch(email)) return;
    final found = await AppConfig.mailRepository.discoverDirectSettings(email);
    if (!mounted || found == null || _serversEdited) return;
    if (email != _email.text.trim()) return;
    setState(() {
      _discovered = found;
      _imapHost.text = found.imap.host;
      _imapPort.text = '${found.imap.port}';
      _imapUser.text = found.imap.username;
      _imapSecurity = found.imap.security;
      _smtpHost.text = found.smtp.host;
      _smtpPort.text = '${found.smtp.port}';
      _smtpUser.text = found.smtp.username;
      _smtpSecurity = found.smtp.security;
      // A guess is shown for checking; a known provider is just used.
      _showServers = found.source == DiscoverySource.guessed;
    });
  }

  void _edited() => _serversEdited = true;

  /// Moves the port along when the security choice changes, as long as the
  /// port was still the usual one for the old choice.
  void _securityChanged(
    TextEditingController port,
    MailSecurity previous,
    MailSecurity next,
    bool smtp,
  ) {
    int usual(MailSecurity s) => smtp
        ? (s == MailSecurity.sslOnConnect ? 465 : 587)
        : (s == MailSecurity.sslOnConnect ? 993 : 143);
    if (port.text.trim() == '${usual(previous)}') {
      port.text = '${usual(next)}';
    }
  }

  String? _requiredHost(String? value) =>
      DirectEndpoint.isValidHostName(value ?? '')
      ? null
      : l10nNow.directHostInvalid;

  String? _validPort(String? value) {
    final port = int.tryParse((value ?? '').trim());
    return port != null && port >= 1 && port <= 65535
        ? null
        : l10nNow.directPortInvalid;
  }

  Future<void> _connect() async {
    if (_busy) return;
    if (_discovered == null && !_serversEdited) await _discover();
    if (!mounted) return;
    if (!_formKey.currentState!.validate()) {
      setState(() => _showServers = true);
      return;
    }
    final email = _email.text.trim();
    final local = email.substring(0, email.indexOf('@'));
    final setup = DirectAccountSetup(
      email: email,
      displayName: _name.text.trim().isEmpty ? local : _name.text.trim(),
      password: _password.text,
      imap: DirectEndpoint(
        host: _imapHost.text.trim(),
        port: int.parse(_imapPort.text.trim()),
        security: _imapSecurity,
        username: _imapUser.text.trim().isEmpty ? email : _imapUser.text.trim(),
      ),
      smtp: DirectEndpoint(
        host: _smtpHost.text.trim(),
        port: int.parse(_smtpPort.text.trim()),
        security: _smtpSecurity,
        username: _smtpUser.text.trim().isEmpty ? email : _smtpUser.text.trim(),
      ),
      smtpPassword: _separateSmtpPassword && _smtpPassword.text.isNotEmpty
          ? _smtpPassword.text
          : null,
    );
    setState(() {
      _busy = true;
      _error = null;
      _suggestion = null;
    });
    try {
      final account = await AppConfig.mailRepository.connectDirectAccount(
        setup,
      );
      unawaited(PushService.requestLocalPermission());
      if (!mounted) return;
      _autofillFinished = true;
      TextInput.finishAutofillContext();
      Navigator.of(context).pop<MailAccount>(account);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is ApiException
            ? error.userMessage
            : friendlyErrorMessage(error);
        if (error is DirectMailException) {
          final host = error.suggestedHost;
          if (host != null && error.endpoint != null) {
            _suggestion = (host: host, which: error.endpoint!);
          }
          // Whatever went wrong, the servers are the likely place to look.
          if (error.kind != DirectErrorKind.authFailed &&
              error.kind != DirectErrorKind.authRequiresAppPassword &&
              error.kind != DirectErrorKind.accountExists) {
            _showServers = true;
          }
        }
      });
    }
  }

  void _useSuggestedHost() {
    final suggestion = _suggestion;
    if (suggestion == null) return;
    setState(() {
      (suggestion.which == 'smtp' ? _smtpHost : _imapHost).text =
          suggestion.host;
      _serversEdited = true;
      _suggestion = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final discovered = _discovered;
    return Scaffold(
      appBar: AppBar(title: Text(l10nNow.directAddTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: AutofillGroup(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _InfoCard(),
                    const SizedBox(height: 20),
                    TextFormField(
                      key: const Key('direct-email-field'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [
                        AutofillHints.email,
                        AutofillHints.username,
                      ],
                      textInputAction: TextInputAction.next,
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.isEmpty) return l10nNow.emailAddressIsRequired;
                        if (!_emailPattern.hasMatch(text)) {
                          return l10nNow.enterAValidEmailAddress2;
                        }
                        return null;
                      },
                      decoration: InputDecoration(
                        labelText: l10nNow.email,
                        prefixIcon: const Icon(LucideIcons.mail, size: 20),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('direct-name-field'),
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l10nNow.directDisplayName,
                        prefixIcon: const Icon(LucideIcons.user, size: 20),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('direct-password-field'),
                      controller: _password,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _connect(),
                      validator: (value) => (value ?? '').isEmpty
                          ? l10nNow.passwordIsRequired
                          : null,
                      decoration: InputDecoration(
                        labelText: l10nNow.password,
                        prefixIcon: const Icon(LucideIcons.lock, size: 20),
                        suffixIcon: IconButton(
                          tooltip: _obscure
                              ? l10nNow.showPassword
                              : l10nNow.hidePassword,
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    if (discovered?.requiresAppPassword == true) ...[
                      const SizedBox(height: 12),
                      _Note(
                        key: const Key('direct-app-password-note'),
                        icon: LucideIcons.keyRound,
                        text: l10nNow.directAppPasswordNote,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Theme(
                      data: Theme.of(context)
                          .copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        key: ValueKey('servers-$_showServers'),
                        initiallyExpanded: _showServers,
                        onExpansionChanged: (open) => _showServers = open,
                        tilePadding: EdgeInsets.zero,
                        title: Text(l10nNow.directServerSettings),
                        subtitle: discovered == null
                            ? null
                            : Text(switch (discovered.source) {
                                DiscoverySource.guessed =>
                                  l10nNow.directDiscoveryGuessed,
                                DiscoverySource.published =>
                                  l10nNow.directDiscoveryPublished,
                                DiscoverySource.known =>
                                  '${discovered.imap.host} · ${discovered.smtp.host}',
                              }, style: TextStyle(color: colors.secondaryText)),
                        children: [
                          _ServerFields(
                            title: l10nNow.directImapSection,
                            keyPrefix: 'imap',
                            host: _imapHost,
                            port: _imapPort,
                            user: _imapUser,
                            security: _imapSecurity,
                            hostValidator: _requiredHost,
                            portValidator: _validPort,
                            onEdited: _edited,
                            onSecurity: (next) => setState(() {
                              _securityChanged(
                                _imapPort,
                                _imapSecurity,
                                next,
                                false,
                              );
                              _imapSecurity = next;
                              _edited();
                            }),
                          ),
                          const SizedBox(height: 16),
                          _ServerFields(
                            title: l10nNow.directSmtpSection,
                            keyPrefix: 'smtp',
                            host: _smtpHost,
                            port: _smtpPort,
                            user: _smtpUser,
                            security: _smtpSecurity,
                            hostValidator: _requiredHost,
                            portValidator: _validPort,
                            onEdited: _edited,
                            onSecurity: (next) => setState(() {
                              _securityChanged(
                                _smtpPort,
                                _smtpSecurity,
                                next,
                                true,
                              );
                              _smtpSecurity = next;
                              _edited();
                            }),
                          ),
                          SwitchListTile(
                            key: const Key('direct-separate-smtp-password'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(l10nNow.directSeparateSmtpPassword),
                            value: _separateSmtpPassword,
                            onChanged: (value) =>
                                setState(() => _separateSmtpPassword = value),
                          ),
                          if (_separateSmtpPassword)
                            TextFormField(
                              key: const Key('direct-smtp-password'),
                              controller: _smtpPassword,
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: l10nNow.directSmtpPassword,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        key: const Key('direct-error'),
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.destructive,
                        ),
                      ),
                    ],
                    if (_suggestion != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          key: const Key('direct-use-suggested-host'),
                          onPressed: _useSuggestedHost,
                          child: Text(
                            l10nNow.directUseSuggestedHost(_suggestion!.host),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('direct-connect-button'),
                      onPressed: _busy ? null : _connect,
                      child: _busy
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            )
                          : Text(l10nNow.connect),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colors.secondaryText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            ),
          ),
        ],
      ),
    );
    return Container(
      key: const Key('direct-info-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10nNow.directIntro),
          line(LucideIcons.bell, l10nNow.directInfoNotifications),
          line(LucideIcons.clock, l10nNow.directInfoScheduled),
          line(LucideIcons.smartphone, l10nNow.directInfoLocalData),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: colors.secondaryText),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: colors.secondaryText),
          ),
        ),
      ],
    );
  }
}

class _ServerFields extends StatelessWidget {
  const _ServerFields({
    required this.title,
    required this.keyPrefix,
    required this.host,
    required this.port,
    required this.user,
    required this.security,
    required this.hostValidator,
    required this.portValidator,
    required this.onEdited,
    required this.onSecurity,
  });

  final String title;
  final String keyPrefix;
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final MailSecurity security;
  final String? Function(String?) hostValidator;
  final String? Function(String?) portValidator;
  final VoidCallback onEdited;
  final ValueChanged<MailSecurity> onSecurity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextFormField(
          key: Key('direct-$keyPrefix-host'),
          controller: host,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => onEdited(),
          validator: hostValidator,
          decoration: InputDecoration(labelText: l10nNow.directHost),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                key: Key('direct-$keyPrefix-port'),
                controller: port,
                keyboardType: TextInputType.number,
                onChanged: (_) => onEdited(),
                validator: portValidator,
                decoration: InputDecoration(labelText: l10nNow.directPort),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<MailSecurity>(
                key: Key('direct-$keyPrefix-security'),
                initialValue: security,
                decoration: InputDecoration(labelText: l10nNow.directSecurity),
                items: [
                  DropdownMenuItem(
                    value: MailSecurity.sslOnConnect,
                    child: Text(l10nNow.directSecurityTls),
                  ),
                  DropdownMenuItem(
                    value: MailSecurity.startTls,
                    child: Text(l10nNow.directSecurityStartTls),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) onSecurity(value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: Key('direct-$keyPrefix-user'),
          controller: user,
          autocorrect: false,
          onChanged: (_) => onEdited(),
          decoration: InputDecoration(labelText: l10nNow.directUsername),
        ),
      ],
    );
  }
}
