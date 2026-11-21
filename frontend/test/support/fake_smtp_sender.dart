import 'dart:async';

import 'package:kaydetmail/services/direct/direct_errors.dart';
import 'package:kaydetmail/services/direct/message_composer.dart';
import 'package:kaydetmail/services/direct/smtp_sender.dart';

/// An [SmtpSender] that keeps what it was given, for tests of everything that
/// decides *whether* to send.
class FakeSmtpSender implements SmtpSender {
  FakeSmtpSender({this.limit});

  final List<ComposedMessage> sent = [];
  int verifies = 0;
  int attempts = 0;
  int? limit;

  /// Thrown by the next call(s), then cleared.
  final List<Object> failures = [];

  /// When set, `send` waits for it, then goes on.
  Completer<void>? gate;

  /// When true, the message is recorded and then a failure is thrown, like a
  /// server that received the data but whose answer never came.
  bool deliverThenFail = false;

  @override
  int? get maxMessageSize => limit;

  @override
  Future<void> verify() async {
    verifies++;
    if (failures.isNotEmpty) throw failures.removeAt(0);
  }

  @override
  Future<SmtpDelivery> send(
    ComposedMessage message, {
    void Function(int sent, int total)? onProgress,
    Future<void>? abort,
  }) async {
    attempts++;
    if (gate != null) await gate!.future;
    if (failures.isNotEmpty) {
      if (deliverThenFail) sent.add(message);
      throw failures.removeAt(0);
    }
    if (limit != null && message.size > limit!) {
      throw DirectMailException(DirectErrorKind.messageTooLarge);
    }
    onProgress?.call(message.size, message.size);
    sent.add(message);
    return const SmtpDelivery(serverReply: '250 queued');
  }
}
