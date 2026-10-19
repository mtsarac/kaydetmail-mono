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

1. **IMAP, MIME and SMTP: `enough_mail_plus` 2.3.x** (pure Dart, MPL-2.0, the
   maintained fork of `enough_mail`). MPL-2.0 permits combination with
   AGPL-3.0 (this repository's license) through its secondary-license clause.
2. **SMTP phase tracking is ours**, as a thin `SmtpClient` subclass that sees
   when `DATA` is written. The library reports one result for a whole send;
   our outbox must never resend a message whose delivery may have started
   (see AGENTS.md), so it needs to know which side of `DATA` a failure fell on.
3. **TLS probe and certificate names: `dart:io` sockets plus `basic_utils`**
   to read subject alternative names for the "wrong server name" hint.
4. **Local store: the existing encrypted sqlite3mc database**, new tables
   prefixed `d_`; backend cache tables are untouched.
5. **Direct errors extend `ApiException`** (`DirectMailException`), with their
   own stable codes. About 30 existing `catch`/`is ApiException` sites keep
   working without edits, and `friendlyErrorMessage` stays the single place
   that turns errors into text.
6. **The direct account registry in `SessionStore` is additive** (its own
   key). The backend keys are not rewritten, so a rollback to an older build
   still sees a valid backend-only list.

## Evidence

Spike against GreenMail 2.1.8 (`java -jar`, no Docker in the sandbox).

Original `enough_mail` 2.1.7:

- **Cannot be added to the app.** It needs `xml ^6`; `pdf 3.13.1` (already a
  dependency) needs `xml ^7`, so pub fails to resolve.
- **SMTP replies are processed per TCP read.** A multi-line reply whose lines
  arrive in separate segments (GreenMail sends `250-…` and `250 …` 43 ms
  apart in a raw-socket capture; TLS records and slow links can do the same
  to real servers) never completes: `EHLO` hung until the server's idle
  timeout.

`enough_mail_plus` 2.3.0 (released 2026-10-15):

- Resolves with the app's dependencies (`xml >=6 <8`) and adds
  `enough_convert`, which covers the legacy Turkish charsets
  (`windows-1254`, `iso-8859-9`).
- Its changelog lists the fixes we would otherwise have written ourselves:
  multi-line SMTP replies split across TCP chunks, SMTP DATA transparency
  (dot-stuffing), IMAP `LOGIN`/mailbox-name quoting, `UNSELECT` instead of
  `CLOSE` on folder switch, IMAP `NAMESPACE` (needed for cPanel's `INBOX.`
  prefix), RFC 2231 parameters, `Bcc` stripping, no silent clear-text
  fallback when STARTTLS is missing.
- Verified here: `EHLO` + `AUTH PLAIN` against GreenMail complete;
  `CAPABILITY` (after an explicit `capability()` call), `LIST`, `SELECT`
  (`UIDVALIDITY`, `UIDNEXT`), `UID FETCH` of flags/headers/full body, Turkish
  subject and body decoding, `UID STORE`, `UID COPY`/`UID MOVE` with
  `COPYUID`, and `IDLE` (a mail arriving during `IDLE` raises
  `ImapMessagesExistEvent` 7→8 on `ImapClient.eventStream`).
- Verified with a local TLS server and a throwaway CA: after `STARTTLS` the
  server name is checked — a certificate that does not cover the host is
  rejected with a `HandshakeException` even though its CA is trusted.

Quirks to code around:

- `ImapServerInfo` has no CONDSTORE getter; we read the raw capability list.
  QRESYNC support exists (`supportsQresync`, `UNCHANGEDSINCE`) but must be
  proven on a real Dovecot before it is relied on. GreenMail offers neither,
  so the no-CONDSTORE path is the one exercised in CI.
- `createMailbox` can throw "Unable to find just created mailbox" against
  GreenMail even though the folder exists; the wrapper re-lists and checks.
- `fetchRecentMessages` positions by sequence number; after `IDLE` pushes we
  always re-sync by UID range, never by sequence.
- The process stays alive after `logout()` until `disconnect()`; the
  connection wrapper always does both.
- After `STARTTLS` the fork re-issues `CAPABILITY` (correct per RFC 3501).

Not verified here (no Docker, no Dovecot/Exim in the sandbox): QRESYNC
against Dovecot, the cPanel certificate-name mismatch with a real host,
background isolates on devices. These are tracked as device/server QA items,
not assumed to work.

## Alternatives considered

- **Original `enough_mail`.** Does not resolve (above).
- **Own SMTP client.** Considered while the SMTP hang looked unfixable; the
  fork removes the reason, and a subclass gives us the one thing we lacked.
- **Rust core via `flutter_rust_bridge` (`async-imap`, `mail-parser`,
  `lettre`).** More robust protocol handling, but a native toolchain in every
  CI job and release build. Revisit if the fork proves unreliable on the
  server matrix.
- **Platform-native clients** (Jakarta Mail, MailCore2): two implementations
  to keep in step.

## Consequences

- One extra pub package family (`enough_mail_plus`, `enough_convert`,
  `basic_utils`, `pointycastle`, `encrypter_plus`, `json_annotation`).
- The fork has a single maintainer. IMAP behaviour that a library bug can
  break is isolated behind `ImapConnection`, which tests drive with a
  scripted fake server; the dependency can be swapped there.
- SMTP phase tracking is ours, so the "delivery uncertain, never resend"
  rule is enforced in code we control.
