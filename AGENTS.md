# Repository Guidelines

## Project Overview

Kaydetmail is a Turkish-language, multi-account mail client. `frontend/` is an offline-first Flutter app; `backend/` is a .NET 10 IMAP/SMTP API backed by PostgreSQL. Mail-server mutations are remote-first; client cache and queued local mutations provide offline behavior.

## Architecture & Data Flow

### Frontend

`lib/app.dart` restores sessions and owns authentication, biometric lock, notification routing, sync scheduling, and outbox recovery. UI code depends on `MailRepository` (`lib/repositories/mail_repository.dart`), a `ChangeNotifier`; `ApiMailRepository` is its sole implementation and owns one account-scoped session per mailbox.

Typical flow:

1. Screen/widget calls `MailRepository` and listens for notifications.
2. `ApiMailRepository` coordinates `ApiAuthService`/`ApiMailService`, account state, and SQLite cache.
3. `ApiClient` performs HTTP, refreshes tokens after `401`, and maps RFC 7807 responses to `ApiException`.
4. Cached mail paints first; API results revalidate it. Offline pin, snooze, label, contact, draft, and send operations persist locally and reconcile later.

Use existing `ChangeNotifier` controllers for cross-widget state (`lib/state/`); do not introduce a second state-management pattern. Keep models immutable and update them with `copyWith`.

### Backend

Dependency direction is `MailClient.Api` → `MailClient.Application` → `MailClient.Domain`, with `MailClient.Infrastructure` implementing application interfaces. `Program.cs` wires ASP.NET Core minimal APIs, EF Core, auth, observability, storage, sync, push, and mail transports through built-in DI.

Request flow: endpoint group → application contract/service → infrastructure implementation → PostgreSQL and remote IMAP/SMTP server. Mail mutations must succeed remotely before local DB state changes. Preserve account ownership checks, IMAP UID/UIDVALIDITY semantics, stable API error codes, idempotency keys, and correlation IDs.

Background flow: `MailSyncService` schedules work, `SyncCoordinator` limits concurrent account jobs, `NewMailSyncExecutor` invokes folder sync, and notifier services enqueue push messages. Scheduled sends use persisted status, optimistic revision checks, and dispatcher retries; delivery-uncertain messages must not be resent automatically.

## Key Directories

- `frontend/lib/models/`: immutable client domain models.
- `frontend/lib/repositories/`: UI-facing repository contract and API implementation.
- `frontend/lib/services/`: HTTP/auth, cache, persistence, notifications, and platform integration.
- `frontend/lib/state/`: shared `ChangeNotifier` state and offline queues.
- `frontend/lib/screens/`, `lib/widgets/`: UI surfaces and reusable widgets.
- `frontend/test/`: Flutter unit and widget tests.
- `backend/backend/src/MailClient.Api/`: host, middleware, and minimal API endpoint groups.
- `backend/backend/src/MailClient.Application/`: DTOs, interfaces, policies, options, runtime settings.
- `backend/backend/src/MailClient.Domain/`: dependency-free entities and enums.
- `backend/backend/src/MailClient.Infrastructure/`: EF Core, MailKit, OAuth, sync, storage, and push implementations.
- `backend/backend/tests/MailClient.Tests/`: xUnit unit, API, security, and integration tests.
- `backend/backend/docs/`: architecture, API, configuration, development, and production guidance.

## Development Commands

Run commands from indicated project directory.

```bash
# Frontend: frontend/
flutter pub get
flutter run
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5071
flutter analyze
flutter test
flutter test test/some_file.dart
flutter test --plain-name "test name"
```

```bash
# Full backend stack: backend/
cp .env.example .env        # set Jwt__Key to 32+ characters
docker compose up --build    # PostgreSQL, GreenMail, migration, API :8080
```

```bash
# Backend CLI: backend/
dotnet restore backend/MailClient.slnx
dotnet build backend/MailClient.slnx --configuration Release --no-restore
dotnet test backend/MailClient.slnx --configuration Release --no-build
dotnet format backend/MailClient.slnx --verify-no-changes
dotnet test backend/tests/MailClient.Tests/MailClient.Tests.csproj --filter 'FullyQualifiedName~TestName'
```

Without Docker, export `KAYDETMAIL_DB_CONNECTION`, then run `dotnet ef database update --project backend/src/MailClient.Infrastructure --startup-project backend/src/MailClient.Api` and `dotnet run --project backend/src/MailClient.Api`. `dotnet run` does not read `.env`.

## Code Conventions & Common Patterns

- Dart: follow `flutter_lints`; files use `snake_case.dart`, types `UpperCamelCase`, members `lowerCamelCase`. Keep async I/O as `Future`/`async`/`await`; notify listeners after state transitions.
- Frontend screens must use `MailRepository`, not call transport/cache layers directly. Scope cache and mutation state by account.
- Convert HTTP/network failures through `ApiException`; retain backend error codes and Turkish user-facing messages.
- C#: nullable references and implicit usings are enabled; warnings are errors. Types/methods use `PascalCase`, locals/parameters `camelCase`, async methods use `Async` suffix.
- Register backend implementations through built-in DI. Keep provider-specific MailKit and persistence code in Infrastructure; Domain must remain dependency-free.
- Endpoint handlers use authenticated account scope and return established problem/error contracts. Do not leak credentials, message bodies, tokens, or account identifiers into logs.
- EF migrations: generate with `dotnet ef migrations add <Name>`. Never hand-write migrations or edit `.Designer.cs`/snapshot files; editing generated `Up()`/`Down()` for required SQL is allowed. Never alter a migration merged to `main`.
- Use conventional commits such as `feat:`, `fix:`, `docs:`, and `chore:`.

## Important Files

- `frontend/lib/main.dart`: Flutter process entry point.
- `frontend/lib/app.dart`: root application and lifecycle coordination.
- `frontend/lib/repositories/mail_repository.dart`: UI contract; update every implementation/test double when changing it.
- `frontend/lib/repositories/api_mail_repository.dart`: multi-account/offline orchestration.
- `frontend/lib/services/api_client.dart`: transport, token refresh, uploads/downloads.
- `frontend/lib/services/mail_cache.dart`: encrypted SQLite mail cache.
- `frontend/pubspec.yaml`, `analysis_options.yaml`: dependencies, Dart constraint, lint config.
- `backend/backend/src/MailClient.Api/Program.cs`: backend composition root.
- `backend/backend/src/MailClient.Domain/Entities.cs`: persisted domain model.
- `backend/backend/src/MailClient.Infrastructure/AppDbContext.cs`: EF model and DbSets.
- `backend/backend/Directory.Build.props`: shared .NET build policy.
- `backend/docker-compose.yml`, `.env.example`: local stack and configuration template.
- `frontend/docs/flutter-api-integration.md` and `backend/backend/docs/en/api-reference.md`: client/server API contracts.

## Runtime/Tooling Preferences

- Frontend requires Flutter with Dart `^3.13.2`; use `flutter pub`, not npm/Bun. SQLite uses the `sqlite3mc` build hook for encrypted-at-rest cache/outbox data.
- Backend requires .NET 10 SDK and NuGet. PostgreSQL 18 and GreenMail 2.1.8 are provided by Docker Compose.
- Backend targets `net10.0`; Release builds must remain warning-free. Docker runtime runs as a non-root user.
- Local API defaults to `:8080` under Compose. Android emulator reaches host through `http://10.0.2.2:5071` when using direct backend run profiles.
- Never commit `.env`, Firebase credentials, certificates, JWT keys, data-protection key rings, or runtime `data/` and `logs/`.

## Testing & QA

Frontend tests use `flutter_test`, `MockClient`, repository doubles, and widget pumping. Name files `<feature>_test.dart`; test observable behavior and account/offline boundaries. Run `flutter analyze` and targeted tests before full `flutter test`.

Backend tests use xUnit, `WebApplicationFactory<Program>`, EF Core InMemory where appropriate, and reusable fakes in `tests/MailClient.Tests/SyncDoubles.cs`. Add API tests for contract/auth changes and service tests for sync, send, security, idempotency, and reconciliation behavior.

External integrations are opt-in locally:

- PostgreSQL: set `MAILCLIENT_TEST_POSTGRES_ADMIN`.
- GreenMail: set `MAILCLIENT_TEST_GREENMAIL=1` or relevant `MAILCLIENT_TEST_GREENMAIL_*` values.
- `MAILCLIENT_SKIP_INTEGRATION` skips external-service tests.

CI runs Release build, NuGet vulnerability audit, xUnit against PostgreSQL/GreenMail, Docker health smoke test, format verification, CodeQL, and dependency review. No numeric coverage threshold is documented; prefer regression tests that prove consumer-visible behavior over coverage-only tests.
