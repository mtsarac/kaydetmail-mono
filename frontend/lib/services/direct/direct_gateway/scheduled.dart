part of '../direct_mail_gateway.dart';

/// Mail written now and sent later.
///
/// With no server behind the account, this device is the clock: a scheduled
/// send goes out when its time comes **while the app is running**, or the
/// next time the app is opened. The capability `guaranteedScheduledSend` is
/// false for direct accounts so the screens can say so.
///
/// Delivery goes through the same journal as an ordinary send, keyed by the
/// scheduled send's id: a send whose outcome is unknown becomes
/// `deliveryUnknown` and is never repeated by itself.
mixin _DirectScheduledApi
    on _DirectGatewayBase, _DirectMailApi, _DirectActionApi, _DirectComposeApi {
  DirectScheduledStore get _scheduled => DirectScheduledStore(store);

  /// Tries a failing send this many times before giving up.
  static const _maxAttempts = 12;
  static const _backoff = [1, 2, 5, 15, 30];

  ScheduledSend _view(ScheduledRow row) => ScheduledSend(
    id: row.id,
    to: row.to,
    cc: row.cc,
    bcc: row.bcc,
    subject: row.subject,
    sendAt: DateTime.fromMillisecondsSinceEpoch(row.sendAtMs),
    status: ScheduledSendStatus.values.byName(row.status),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdMs),
    sentMailId: row.sentLocalId,
    failureReason: _reasonText(row.failureReason),
    attemptCount: row.attempts,
    nextAttemptAtUtc: row.nextAttemptMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row.nextAttemptMs!, isUtc: true),
  );

  /// The stored reason code as text the user can read.
  static String? _reasonText(String? code) {
    if (code == null) return null;
    for (final kind in DirectErrorKind.values) {
      if (kind.code == code) return DirectMailException(kind).userMessage;
    }
    return ApiException(status: 0, code: code).userMessage;
  }

  void _requireFuture(DateTime sendAt) {
    if (!sendAt.isAfter(_clock())) {
      throw const ApiException(status: 400, code: 'scheduled_send_in_past');
    }
  }

  List<ScheduledFile> _filesOf(List<Attachment> attachments) => [
    for (final a in attachments)
      if (a.bytes != null)
        ScheduledFile(
          id: '',
          name: a.name,
          mime: a.mimeType,
          size: a.bytes!.length,
          content: a.bytes,
        ),
  ];

  Future<ScheduledSend> scheduleSend({
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    List<Attachment> attachments = const [],
    String? replySourceMailId,
    String? identityId,
    bool requestReadReceipt = false,
    required DateTime sendAtUtc,
    required String idempotencyKey,
  }) async {
    final existing = _scheduled.findByKey(accountId, idempotencyKey);
    if (existing != null) return _view(existing);
    _requireFuture(sendAtUtc);
    // Building the message now reports bad recipients and oversized
    // attachments while the user is still looking at the screen.
    _build(
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      bodyText: bodyText,
      bodyHtml: bodyHtml,
      attachments: attachments,
      replySourceMailId: replySourceMailId,
      identityId: identityId,
      requestReadReceipt: requestReadReceipt,
    );
    final row = _scheduled.create(
      accountId,
      createKey: idempotencyKey,
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      bodyText: bodyText,
      bodyHtml: bodyHtml,
      replySource: replySourceMailId,
      identityId: identityId,
      readReceipt: requestReadReceipt,
      sendAt: sendAtUtc,
      files: _filesOf(attachments),
    );
    _armScheduler();
    return _view(row);
  }

  Future<void> cancelScheduledSend(String id) async {
    final row = _scheduled.require(accountId, id);
    switch (row.status) {
      case 'pending' || 'failed' || 'deliveryUnknown':
        _scheduled.removeFiles(accountId, id);
        _scheduled.setStatus(accountId, id, 'cancelled');
        _armScheduler();
      case 'sent':
        throw const ApiException(
          status: 409,
          code: 'scheduled_send_already_sent',
        );
      default:
        break; // Already cancelled: idempotent.
    }
  }

  Future<ScheduledSendDetail> getScheduledSend(String id) async {
    final row = _scheduled.require(accountId, id);
    return ScheduledSendDetail(
      id: row.id,
      revision: row.revision,
      to: row.to,
      cc: row.cc,
      bcc: row.bcc,
      subject: row.subject,
      bodyText: row.bodyText,
      bodyHtml: row.bodyHtml,
      sendAt: DateTime.fromMillisecondsSinceEpoch(row.sendAtMs),
      attachments: [
        for (final file in _scheduled.files(accountId, id))
          ScheduledSendAttachmentInfo(
            id: file.id,
            name: file.name,
            mimeType: file.mime,
            sizeBytes: file.size,
          ),
      ],
    );
  }

  Future<void> updateScheduledSend({
    required String id,
    required int expectedRevision,
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    required DateTime sendAtUtc,
    List<String> keepAttachmentIds = const [],
    List<Attachment> attachments = const [],
  }) async {
    final row = _scheduled.require(accountId, id);
    if (row.status == 'sent') {
      throw const ApiException(
        status: 409,
        code: 'scheduled_send_already_sent',
      );
    }
    if (row.status != 'pending') {
      throw const ApiException(status: 409, code: 'scheduled_send_not_pending');
    }
    if (row.revision != expectedRevision) {
      throw const ApiException(status: 409, code: 'scheduled_send_modified');
    }
    _requireFuture(sendAtUtc);
    final kept = _scheduled
        .files(accountId, id, withContent: true)
        .where((f) => keepAttachmentIds.contains(f.id))
        .toList();
    if (keepAttachmentIds.any((k) => !kept.any((f) => f.id == k))) {
      throw const ApiException(
        status: 404,
        code: 'scheduled_send_attachment_not_found',
      );
    }
    _build(
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      bodyText: bodyText,
      bodyHtml: bodyHtml,
      attachments: [
        for (final f in kept)
          Attachment(
            name: f.name,
            sizeBytes: f.size,
            bytes: f.content,
            mimeType: f.mime,
          ),
        ...attachments,
      ],
      replySourceMailId: row.replySource,
      identityId: row.identityId,
      requestReadReceipt: row.readReceipt,
    );
    store.transaction(() {
      _scheduled.removeFiles(accountId, id, except: keepAttachmentIds.toSet());
      for (final file in _filesOf(attachments)) {
        _scheduled.putFile(accountId, id, file);
      }
      _scheduled.update(
        accountId,
        id,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: subject,
        bodyText: bodyText,
        bodyHtml: bodyHtml,
        sendAt: sendAtUtc,
      );
    });
    _armScheduler();
  }

  /// A failed (or unknown-outcome) send queued again as a new one. The old
  /// entry is withdrawn.
  Future<void> rescheduleFailedSend({
    required String id,
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required String subject,
    String bodyText = '',
    String? bodyHtml,
    List<String>? attachmentIds,
    required DateTime sendAtUtc,
    required String idempotencyKey,
  }) async {
    if (_scheduled.findByKey(accountId, idempotencyKey) != null) return;
    final row = _scheduled.require(accountId, id);
    if (row.status != 'failed' && row.status != 'deliveryUnknown') {
      throw const ApiException(status: 409, code: 'scheduled_send_not_pending');
    }
    _requireFuture(sendAtUtc);
    final files = [
      for (final f in _scheduled.files(accountId, id, withContent: true))
        if (attachmentIds == null || attachmentIds.contains(f.id)) f,
    ];
    store.transaction(() {
      _scheduled.create(
        accountId,
        createKey: idempotencyKey,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: subject,
        bodyText: bodyText,
        bodyHtml: bodyHtml,
        replySource: row.replySource,
        identityId: row.identityId,
        readReceipt: row.readReceipt,
        sendAt: sendAtUtc,
        files: [
          for (final f in files)
            ScheduledFile(
              id: '',
              name: f.name,
              mime: f.mime,
              size: f.size,
              content: f.content,
            ),
        ],
      );
      _scheduled.removeFiles(accountId, id);
      _scheduled.setStatus(accountId, id, 'cancelled');
    });
    _armScheduler();
  }

  Future<List<ScheduledSend>> listScheduledSends() async => [
    for (final row in _scheduled.visible(accountId)) _view(row),
  ];

  // --- Sending them when the time comes ----------------------------------------------

  bool _dispatching = false;

  /// Sends everything that is due. Safe to call at any time; only one run
  /// happens at once. Returns how many went out.
  Future<int> runDueScheduledSends() async {
    if (_dispatching) return 0;
    _dispatching = true;
    var sent = 0;
    var changed = false;
    try {
      for (final row in _scheduled.due(accountId)) {
        changed = true;
        if (await _dispatch(row)) sent++;
      }
    } finally {
      _dispatching = false;
    }
    if (changed) {
      _emit(const GatewayEvent(GatewayEventKind.scheduledSends));
      final folder = store.folderByRole(accountId, FolderRole.sent);
      if (sent > 0 && folder != null) {
        _emit(GatewayEvent(GatewayEventKind.mail, folderId: folder.folderId));
      }
    }
    _armScheduler();
    return sent;
  }

  Future<bool> _dispatch(ScheduledRow row) async {
    try {
      final files = _scheduled.files(accountId, row.id, withContent: true);
      final message = _build(
        to: row.to,
        cc: row.cc,
        bcc: row.bcc,
        subject: row.subject,
        bodyText: row.bodyText,
        bodyHtml: row.bodyHtml,
        attachments: [
          for (final f in files)
            Attachment(
              name: f.name,
              sizeBytes: f.size,
              bytes: f.content,
              mimeType: f.mime,
            ),
        ],
        replySourceMailId: row.replySource,
        identityId: row.identityId,
        requestReadReceipt: row.readReceipt,
      );
      final delivered = await _deliver(
        'scheduled-${row.id}',
        message,
        subject: row.subject,
        replySourceMailId: row.replySource,
      );
      _scheduled.setStatus(
        accountId,
        row.id,
        'sent',
        sentLocalId: delivered.localId,
      );
      _scheduled.removeFiles(accountId, row.id);
      return true;
    } on DirectMailException catch (error) {
      switch (error.kind) {
        case DirectErrorKind.deliveryUncertain:
          _scheduled.setStatus(
            accountId,
            row.id,
            'deliveryUnknown',
            failureReason: error.code,
          );
        case DirectErrorKind.smtpRejected ||
            DirectErrorKind.smtpSenderRejected ||
            DirectErrorKind.smtpRecipientRejected ||
            DirectErrorKind.messageTooLarge ||
            DirectErrorKind.authFailed ||
            DirectErrorKind.authRequiresAppPassword ||
            DirectErrorKind.authMethodUnsupported:
          _scheduled.setStatus(
            accountId,
            row.id,
            'failed',
            failureReason: error.code,
          );
        default:
          // Offline, a timeout, a busy server: wait and try again.
          if (row.attempts + 1 >= _maxAttempts) {
            _scheduled.setStatus(
              accountId,
              row.id,
              'failed',
              failureReason: error.code,
            );
          } else {
            final minutes = _backoff[min(row.attempts, _backoff.length - 1)];
            _scheduled.retryLater(
              accountId,
              row.id,
              _clock().add(Duration(minutes: minutes)),
              error.code ?? 'network_unavailable',
            );
          }
      }
      return false;
    } on ApiException catch (error) {
      // Something about the message itself (an identity that was deleted).
      _scheduled.setStatus(
        accountId,
        row.id,
        'failed',
        failureReason: error.code ?? 'mail_operation_failed',
      );
      return false;
    }
  }

  /// Sets the timer that wakes the gateway for the next due send.
  void _armScheduler() {
    _schedulerTimer?.cancel();
    _schedulerTimer = null;
    final tick = schedulerTick;
    if (tick == null) return;
    final next = _scheduled.nextDueMs(accountId);
    if (next == null) return;
    final wait = next - _clock().millisecondsSinceEpoch;
    final delay = Duration(milliseconds: wait.clamp(1000, tick.inMilliseconds));
    _schedulerTimer = Timer(delay, () {
      unawaited(runDueScheduledSends().catchError((Object _) => 0));
    });
  }
}
