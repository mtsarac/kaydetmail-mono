part of '../direct_mail_gateway.dart';

/// Device sessions are a backend idea: a direct account has no login to
/// revoke. Screens check `AccountCapabilities.deviceSessions` first and never
/// reach these.
mixin _DirectSessionsApi on _DirectGatewayBase {
  Future<List<MailSession>> getSessions() async =>
      throw DirectMailException(DirectErrorKind.unsupportedOperation);

  Future<void> deleteSession(String sessionId) async =>
      throw DirectMailException(DirectErrorKind.unsupportedOperation);
}
