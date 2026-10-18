# Mail Client Backend

🇹🇷 [Türkçe](README.tr.md)

IMAP/SMTP mail client API built with .NET 10 and PostgreSQL. One mailbox can be
signed in from several devices; the API syncs mail from the remote server,
serves it to the client, and applies mutations (read, move, trash, send…) on the
mail server first.

Mail details load ordinary remote images automatically. Junk mail and messages
with `dmarc=fail` need an explicit `remoteContent=allow` request to load them.
Small or hidden tracking pixels, scripts, and remote resources other than images
remain blocked. Other images may disclose when a message was opened. See the
[mail API](docs/en/api-reference.md#mail).

## Quick start

```bash
cp .env.example .env        # set at least Jwt__Key (32+ chars)
docker compose up --build   # Postgres + GreenMail + migrations + API on :8080
```

Swagger UI is available at `/swagger` in the Development environment.
Health probes: `/health/live`, `/health/ready`.

Without Docker: see [Development](docs/en/development.md).

## Repository layout

| Path | Contents |
|------|----------|
| `src/MailClient.Api` | Program, middleware, endpoint groups |
| `src/MailClient.Application` | Contracts, options, interfaces, runtime settings |
| `src/MailClient.Domain` | Entities and enums |
| `src/MailClient.Infrastructure` | EF Core, MailKit, OAuth, push, storage, sync |
| `tests/MailClient.Tests` | Unit and integration tests |
| `docs/` | Documentation |

## Documentation

| Topic | English | Türkçe |
|-------|---------|--------|
| Architecture | [architecture](docs/en/architecture.md) | [architecture](docs/tr/architecture.md) |
| API reference | [api-reference](docs/en/api-reference.md) | [api-reference](docs/tr/api-reference.md) |
| Authentication | [authentication](docs/en/authentication.md) | [authentication](docs/tr/authentication.md) |
| Configuration | [configuration](docs/en/configuration.md) | [configuration](docs/tr/configuration.md) |
| Development | [development](docs/en/development.md) | [development](docs/tr/development.md) |
| Production | [production](docs/en/production.md) | [production](docs/tr/production.md) |

Also: [Docker](docs/DOCKER.md) · [Observability](OBSERVABILITY.md) ·
[Flutter integration guide (TR)](docs/flutter-api-integration.md)

## License

See [LICENSE](LICENSE).
