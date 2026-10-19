part of '../direct_mail_gateway.dart';

/// What a mail server has no place for: pins, snoozes, labels, contacts,
/// trusted senders, templates, signatures and sending identities. They live
/// in the local store and belong to this device (the capability
/// `crossDeviceMetadata` says so), and they follow a mail through moves
/// because they hang on its stable local id.
mixin _DirectLocalApi on _DirectGatewayBase {
  static const _defaultsKey = 'signature_defaults';

  DirectMetaStore get _meta => DirectMetaStore(store);

  // --- Pins and snoozes --------------------------------------------------------

  Future<List<BulkActionResult>> setPinned(
    List<String> mailIds,
    bool pinned,
  ) async {
    final results = <BulkActionResult>[];
    for (final id in mailIds.toSet()) {
      if (!pinned) {
        _meta.unpin(accountId, id);
        results.add(BulkActionResult(mailId: id, success: true));
      } else if (store.message(accountId, id) == null) {
        results.add(
          BulkActionResult(mailId: id, success: false, code: 'mail_not_found'),
        );
      } else if (_meta.pin(accountId, id)) {
        results.add(BulkActionResult(mailId: id, success: true));
      } else {
        results.add(
          BulkActionResult(
            mailId: id,
            success: false,
            code: 'pinned_limit_reached',
          ),
        );
      }
    }
    return results;
  }

  Future<List<String>> getPinnedMailIds() async => _meta.pinned(accountId);

  Future<void> setSnooze(String mailId, DateTime untilUtc) async =>
      _meta.snooze(accountId, mailId, untilUtc);

  Future<void> clearSnooze(String mailId) async =>
      _meta.unsnooze(accountId, mailId);

  Future<Map<String, DateTime>> getSnoozed() async => _meta.snoozed(accountId);

  // --- Trusted senders ---------------------------------------------------------------

  TrustedSender _trusted(TrustedRow row) => TrustedSender(
    id: row.id,
    kind: TrustedSenderKind.fromApi(row.kind),
    value: row.value,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdMs, isUtc: true),
  );

  Future<List<TrustedSender>> getTrustedSenders() async => [
    for (final row in _meta.trustedSenders(accountId)) _trusted(row),
  ];

  Future<TrustedSender> addTrustedSender(
    TrustedSenderKind kind,
    String value,
  ) async => _trusted(_meta.addTrustedSender(accountId, kind.apiValue, value));

  Future<void> removeTrustedSender(String id) async =>
      _meta.removeTrustedSender(accountId, id);

  // --- Labels ----------------------------------------------------------------------------------

  Map<String, dynamic> _label(LabelRow row) => {
    'id': row.id,
    'name': row.name,
    'color': row.color,
  };

  Future<List<Map<String, dynamic>>> getLabels() async => [
    for (final row in _meta.labels(accountId)) _label(row),
  ];

  Future<Map<String, dynamic>> createLabel(String name, int color) async =>
      _label(_meta.createLabel(accountId, name, color));

  Future<Map<String, dynamic>> updateLabel(
    String id,
    String name,
    int color,
  ) async => _label(_meta.updateLabel(accountId, id, name, color));

  Future<void> deleteLabel(String id) async => _meta.deleteLabel(accountId, id);

  Future<Map<String, List<String>>> getLabelAssignments() async =>
      _meta.labelAssignments(accountId);

  Future<void> assignLabels(
    List<String> mailIds,
    List<String> labelIds,
  ) async => _meta.assignLabels(accountId, mailIds, labelIds);

  Future<void> unassignLabels(
    List<String> mailIds,
    List<String> labelIds,
  ) async => _meta.unassignLabels(accountId, mailIds, labelIds);

  // --- Contacts --------------------------------------------------------------------------------

  Map<String, dynamic> _contact(ContactRow row) => {
    'id': row.id,
    'email': row.email,
    'displayName': row.displayName,
  };

  Future<List<Map<String, dynamic>>> getContacts() async => [
    for (final row in _meta.contacts(accountId)) _contact(row),
  ];

  Future<Map<String, dynamic>> createContact(
    String email,
    String? displayName,
  ) async => _contact(_meta.createContact(accountId, email, displayName));

  Future<Map<String, dynamic>> updateContact(
    String id,
    String email,
    String? displayName,
  ) async => _contact(_meta.updateContact(accountId, id, email, displayName));

  Future<void> deleteContact(String id) async =>
      _meta.deleteContact(accountId, id);

  // --- Templates ----------------------------------------------------------------------------

  static DateTime _at(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  MailTemplate _template(TemplateRow row) => MailTemplate(
    id: row.id,
    name: row.name,
    subject: row.subject,
    bodyText: row.bodyText,
    createdAt: _at(row.createdMs),
    updatedAt: _at(row.updatedMs),
  );

  Future<List<MailTemplate>> getTemplates() async => [
    for (final row in _meta.templates(accountId)) _template(row),
  ];

  Future<MailTemplate> createTemplate(MailTemplate template) async => _template(
    _meta.createTemplate(
      accountId,
      name: template.name,
      subject: template.subject,
      bodyText: template.bodyText,
    ),
  );

  Future<MailTemplate> updateTemplate(MailTemplate template) async => _template(
    _meta.updateTemplate(
      accountId,
      template.id,
      name: template.name,
      subject: template.subject,
      bodyText: template.bodyText,
    ),
  );

  Future<void> deleteTemplate(String id) async =>
      _meta.deleteTemplate(accountId, id);

  // --- Signatures ----------------------------------------------------------------------------

  MailSignature _signature(SignatureRow row) => MailSignature(
    id: row.id,
    name: row.name,
    bodyText: row.bodyText,
    createdAt: _at(row.createdMs),
    updatedAt: _at(row.updatedMs),
  );

  SignatureDefaults _defaults() {
    final raw = store.setting(accountId, _defaultsKey);
    if (raw == null) return const SignatureDefaults();
    try {
      final known = {for (final s in _meta.signatures(accountId)) s.id};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      String? keep(String key) {
        final id = json[key] as String?;
        return id != null && known.contains(id) ? id : null;
      }

      return SignatureDefaults(
        newMailSignatureId: keep('newMailSignatureId'),
        replySignatureId: keep('replySignatureId'),
        forwardSignatureId: keep('forwardSignatureId'),
      );
    } catch (_) {
      return const SignatureDefaults();
    }
  }

  Future<({List<MailSignature> items, SignatureDefaults defaults})>
  getSignatures() async => (
    items: [for (final row in _meta.signatures(accountId)) _signature(row)],
    defaults: _defaults(),
  );

  Future<MailSignature> createSignature(MailSignature signature) async =>
      _signature(
        _meta.createSignature(
          accountId,
          name: signature.name,
          bodyText: signature.bodyText,
        ),
      );

  Future<MailSignature> updateSignatureItem(MailSignature signature) async =>
      _signature(
        _meta.updateSignature(
          accountId,
          signature.id,
          name: signature.name,
          bodyText: signature.bodyText,
        ),
      );

  Future<void> deleteSignature(String id) async {
    _meta.deleteSignature(accountId, id);
    store.putSetting(accountId, _defaultsKey, jsonEncode(_defaults().toJson()));
  }

  Future<SignatureDefaults> updateSignatureDefaults(
    SignatureDefaults defaults,
  ) async {
    final known = {for (final s in _meta.signatures(accountId)) s.id};
    for (final id in [
      defaults.newMailSignatureId,
      defaults.replySignatureId,
      defaults.forwardSignatureId,
    ]) {
      if (id != null && !known.contains(id)) {
        throw const ApiException(status: 404, code: 'signature_not_found');
      }
    }
    store.putSetting(accountId, _defaultsKey, jsonEncode(defaults.toJson()));
    return _defaults();
  }

  // --- Sending identities --------------------------------------------------------------------

  MailIdentity _identity(IdentityRow row) => MailIdentity(
    id: row.id,
    emailAddress: row.email,
    displayName: row.displayName,
    replyTo: row.replyTo,
    signatureId: row.signatureId,
    isDefault: row.isDefault,
  );

  Future<List<MailIdentity>> getIdentities() async => [
    for (final row in _meta.identities(accountId)) _identity(row),
  ];

  Future<MailIdentity> createIdentity(MailIdentity identity) async => _identity(
    _meta.createIdentity(
      accountId,
      email: identity.emailAddress,
      displayName: identity.displayName,
      replyTo: identity.replyTo,
      signatureId: identity.signatureId,
      isDefault: identity.isDefault,
    ),
  );

  Future<MailIdentity> updateIdentity(MailIdentity identity) async => _identity(
    _meta.updateIdentity(
      accountId,
      identity.id,
      email: identity.emailAddress,
      displayName: identity.displayName,
      replyTo: identity.replyTo,
      signatureId: identity.signatureId,
      isDefault: identity.isDefault,
    ),
  );

  Future<void> deleteIdentity(String id) async =>
      _meta.deleteIdentity(accountId, id);
}
