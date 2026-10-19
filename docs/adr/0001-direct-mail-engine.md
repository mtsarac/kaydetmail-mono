# ADR 0001 — Direct IMAP/SMTP engine for accounts without a backend

Status: accepted · Scope: `frontend/lib/services/direct/`

## Context

KaydetMail accounts reach their mailbox through the backend API. We want an
account to be able to connect to its IMAP/SMTP servers straight from the
device instead, per account, next to backend accounts, with the same UI.

The app talks to one account through a gateway (`MailGateway`); everything
above it (unified inbox, optimistic updates, routing writes to the owning
account) is shared. The engine behind the direct gateway needs: an IMAP
client, MIME parsing and building, SMTP submission, a TLS probe and a
persistent local store.

## Decision

1. **IMAP and MIME: `enough_mail` (pure Dart, MPL-2.0).** MPL-2.0 permits
   combination with AGPL-3.0 (this repository's license) through its
   secondary-license clause.
2. **SMTP: our own small client** (`direct/smtp_client.dart`), not
   `enough_mail`'s.
3. **TLS probe and certificate names: `dart:io` sockets plus `basic_utils`**
   (already a transitive dependency of `enough_mail`) to read subject
   alternative names.
4. **Local store: the existing encrypted sqlite3mc database**, new tables
   prefixed `d_`; backend cache tables are untouched.
5. **Direct errors extend `ApiException`** (`DirectMailException`), with their
   own stable codes. About 30 existing `catch`/`is ApiException` sites keep
   working without edits, and `friendlyErrorMessage` stays the single place
   that turns errors into text.
6. **The direct account registry in `SessionStore` is additive** (its own
   key). The backend keys are not rewritten, so a rollback to an older build
   still sees a valid backend-only list.

## Evidence (spike against GreenMail 2.1.8, `enough_mail` 2.1.7)

Worked: connect/login, `CAPABILITY` (parsed after an explicit
`capability()` call; not populated by `login` alone), `LIST`, `SELECT`
(`UIDVALIDITY`, `UIDNEXT`), `FETCH` with `ENVELOPE`/`BODYSTRUCTURE`/
`BODY.PEEK[]`, Turkish `Subject` and body decoding, `STORE`, `COPY`, `MOVE`,
`UID SEARCH`, `IDLE` (a mail arriving during `IDLE` raised
`ImapMessagesExistEvent` 6→7).

Found:

- **SMTP replies are processed per TCP read.** `enough_mail` builds a reply
  from the lines of one socket read (`SmtpClient.onDataReceived`) and decides
  `EHLO` is complete when that read holds more than one line. When a server
  sends `250-…` and `250 …` in separate segments (GreenMail does,
  43 ms apart in a raw-socket capture; TLS records and slow links can do the
  same to real servers) the second line becomes a
  one-line reply, the command never completes, and the client hangs until the
  server's idle timeout. Reproduced: `EHLO` never returned against GreenMail.
- **`sendMessage` does not expose where a failure happened** (before or after
  `DATA`). Our outbox must never resend a message whose delivery may have
  started (see AGENTS.md), so we need exact phases:
  `connect → auth → MAIL FROM → RCPT TO → DATA → 250`.
  Both points are why SMTP is ours. It is about 300 lines and fully
  scriptable in tests.
- `ImapServerInfo` has no CONDSTORE getter (`supportsCondStore` does not
  compile); we read the raw capability list ourselves. QRESYNC support exists
  (`supportsQresync`, `UNCHANGEDSINCE`) but must be proven on a real Dovecot
  before it is relied on; GreenMail offers neither CONDSTORE nor QRESYNC, so
  the no-CONDSTORE path is the one exercised in CI.
- `fetchRecentMessages` positions by sequence number; after `IDLE` pushes we
  always re-sync by UID range, never by sequence.
- After `logout()` the process stays alive until `disconnect()`; the
  connection wrapper always does both.

Not verified here (no Docker, no Dovecot/Exim in the sandbox): QRESYNC against
Dovecot, STARTTLS and implicit-TLS handshakes against a CA-signed server,
the cPanel certificate-name mismatch, background isolates on devices. These
are tracked as device/server QA items, not assumed to work.

## Alternatives considered

- **Rust core via `flutter_rust_bridge` (`async-imap`, `mail-parser`,
  `lettre`).** More robust protocol handling, but a native toolchain in every
  CI job and release build. Revisit if `enough_mail` proves unreliable on the
  server matrix.
- **`enough_mail_plus` fork.** Same architecture, same SMTP reply handling;
  no benefit for this problem.
- **Platform-native clients** (Jakarta Mail, MailCore2): two implementations
  to keep in step.

## Consequences

- The direct engine depends on one extra pub package (`enough_mail`, plus its
  transitive packages).
- IMAP behaviour that a library bug can break is isolated behind
  `ImapConnection`, which tests drive with a scripted fake server.
- SMTP phase tracking is ours, so the "delivery uncertain, never resend"
  rule is enforced in code we control.
