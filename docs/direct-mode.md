# Direct mode: an account without the KaydetMail backend

An account is connected one of two ways, chosen when it is added and never
changed afterwards (switching means removing the account and adding it again):

| | Backend | Direct |
|---|---|---|
| Talks to | the KaydetMail API | the user's own IMAP and SMTP servers |
| Mail is stored | on the backend, cached on the device | on the device (encrypted SQLite) |
| New-mail alerts | push (FCM) from the backend | the app, while it runs (see below) |
| Scheduled send | the backend's clock, fires with the app closed | this device, while the app runs |
| Pins, labels, contacts, templates, signatures | on the backend, follow the account | on this device only |
| Device sessions | listed and revocable | none |

`AccountCapabilities` (`lib/models/account_capabilities.dart`) names every
difference. Screens ask `MailRepository.capabilitiesOf(accountId)`; they never
look at the mode.

## Layers

```
screens ──▶ MailRepository ──▶ MailGateway ─┬─▶ ApiMailService          (HTTP → backend)
                                            └─▶ DirectMailGateway       (IMAP/SMTP + local store)
```

`MailGateway` (`lib/services/gateway/`) is everything the repository modules
need from "the other side". `ApiMailService` implements it over HTTP;
`DirectMailGateway` (`lib/services/direct/`) implements it over a local store
and the mail servers. The repository modules (optimistic updates, offline
queue, unified inbox, labels, …) are shared and unchanged.

`DirectMailGateway` is one class assembled from mixins in
`lib/services/direct/direct_gateway/` (account, folders, mail, actions, local
features, compose, scheduled, search, watch), the same way `ApiMailService` is
assembled from its endpoint groups.

### Pieces

* `EnoughImapService` / `EnoughSmtpSender` — adapters over `enough_mail_plus`
  (see `docs/adr/0001-direct-mail-engine.md` for why). Everything above them
  is tested against the in-memory `FakeImapService` / `FakeSmtpSender`; the
  adapters themselves against GreenMail.
* `DirectConnection` + `ConnectionPolicy` — one IMAP connection per account,
  work queued one at a time, sign-in once, **no retry after a refused
  password**, back-off 30 s → 30 min, a 15-minute quiet period when the server
  says "too many". Servers (cPanel especially) block clients that hammer them.
* `DirectStore` / `DirectMetaStore` / `DirectScheduledStore` /
  `DirectSendJournal` — tables `d_*` in the existing encrypted database, every
  row keyed by `account_id`, versioned append-only migrations (`d_schema`).
* `SyncEngine` — the portable UID-based algorithm (RFC 4549): first sync takes
  the newest window, new mail is the UIDs above the highest stored one,
  removals are stored UIDs the server no longer lists, flags are re-read for the
  newest messages. UIDVALIDITY changes detach rows (keeping their local ids) and
  re-bind them by Message-ID, so pins and labels survive.
* `MimeProcessor` + `MailHtmlSanitizer` — parsing, charsets (windows-1254,
  iso-8859-9), HTML sanitising with the same rules as the backend's renderer
  (no scripts, no `style`, remote content blocked, tracking pixels always).
* `MessageComposer` — outgoing MIME (7-bit safe, RFC 2231 file names, no `Bcc`
  on the wire, `Bcc` kept in the Sent copy).
* `SettingsDiscovery`, `CertificateHint` — server settings from a table of
  known providers, the domain's published autoconfig, or `mail.<domain>`; a
  "certificate is for another name" failure says which name to use.

## Rules that must not be broken

* **Server first.** A change reaches the mail server before the local store
  changes. When the server cannot be reached the result is retryable and the
  repository's existing offline queue replays it.
* **UIDs mean nothing across a UIDVALIDITY change.** Every action selects the
  folder and compares UIDVALIDITY first (`mailbox_changed`).
* **A send whose outcome is unknown is never repeated.** `TrackingSmtpClient`
  records whether the server answered `354`; after that point a lost
  connection is `delivery_unknown`. The send journal (`d_sends`, keyed by the
  app's idempotency key) answers a retry of a finished send from the record
  and refuses a retry of an unknown one.
* **No second sign-in after a refusal.** Neither IMAP nor SMTP; both wait for
  the user to supply a new password (`reconnect`).
* Credentials live in the platform keystore (iOS: `first_unlock_this_device`),
  never in SQLite or logs. Error causes are kept on the exception and never
  shown or logged.

## What does not work, and why

* **Notifications with the app closed.** There is no server to push. The app
  watches the Inbox (IMAP IDLE, or polling every 90 s) while it is open and for
  ten minutes after it leaves the foreground, and shows local notifications for
  mail that arrives in that time. Background execution (WorkManager on Android,
  `BGAppRefreshTask` on iOS) is **not implemented**: it needs native setup that
  could not be built and tried in the environment this was written in. The sync
  engine takes a time budget (`FolderSyncReport.stoppedEarly`) so it can be
  wired up later.
* **Scheduled send with the app closed.** It goes out the next time the app is
  opened. The scheduled-sends screen says so.
* **Server-side search for non-ASCII text.** IMAP `SEARCH` needs `CHARSET
  UTF-8`; the client library quotes strings as they are, so such searches stay
  on the device (which folds Turkish letters: `İ ı I i` are one letter, `ş` = `s`).
* **S/MIME and PGP** are detected and shown; signatures are reported as "could
  not be verified".
* **Gmail and Outlook.com** refuse the account password for IMAP/SMTP; the user
  needs an app password. XOAUTH2 is not implemented.
* **CONDSTORE / QRESYNC** are implemented against the in-memory server but off
  by default (`SyncOptions.useCondStore`): they have not been proven on a real
  Dovecot.

## Tests

* Unit tests: `flutter test` — `test/direct_*_test.dart`. Fakes live in
  `test/support/` (`FakeImapService`, `FakeSmtpSender`, `FakeSmtpServer` for the
  real SMTP client over a socket, `DirectRig` wiring a whole gateway).
* Against a real server: GreenMail 2.1.8, same variables as the backend's tests.

  ```bash
  docker run -d -p 3143:3143 -p 3025:3025 \
    -e GREENMAIL_OPTS="-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=test@localhost:test123" \
    greenmail/standalone:2.1.8
  MAILCLIENT_TEST_GREENMAIL=1 flutter test test/integration
  ```

  `MAILCLIENT_SKIP_INTEGRATION` switches them off. CI runs them with a GreenMail
  service container.
* GreenMail is not a faithful Dovecot. Known differences found while testing: it
  reads a new folder name relative to the old folder's parent on `RENAME`
  (the gateway checks the server's own list afterwards, so it treats this as a
  failure instead of corrupting its paths), it drops the connection when the
  selected folder is deleted, and its `MOVE` answers with an untagged
  `COPYUID`.
