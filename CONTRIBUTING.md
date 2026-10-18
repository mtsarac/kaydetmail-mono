# Katkı Rehberi / Contributing

Katkı yapmak istediğiniz için teşekkürler. / Thanks for contributing.

## Başlarken / Getting started

1. Repoyu fork'layın / Fork the repo.
2. Dal açın / Create a branch: `git checkout -b feat/ozellik`.
3. Değişikliği yapıp commit'leyin / Commit your change.
4. `main`'e karşı PR açın / Open a PR against `main`.

Geliştirme komutları (frontend / backend) için [`AGENTS.md`](AGENTS.md) dosyasına bakın. / See `AGENTS.md` for dev commands.

## PR kontrol listesi / PR checklist

- Frontend: `flutter analyze` ve `flutter test`.
- Backend: `dotnet build backend/MailClient.slnx --configuration Release` (uyarısız / warning-free), `dotnet test`, `dotnet format --verify-no-changes`.
- Yeni davranış testle kapsanmalı; kullanıcıya görünen değişiklikte doküman güncellenmeli.
- `.env`, Firebase kimlik bilgileri, sertifika, JWT anahtarı, `data/`, `logs/` asla commit'lenmez. / Never commit secrets.

## Issue kuralları / Issue conventions

Issue formlarını kullanın. Etiketler: `bug`, `enhancement`, `P0`–`P3`, `impact: *`, `area: *`. Ayrıntı: [`LABELS.md`](LABELS.md).

## Commit stili / Commit style

Conventional commits: `type(scope): açıklama`

```
feat(frontend): add offline snooze queue
fix(backend): keep UIDVALIDITY on folder resync
docs(readme): add English README
```

Türler / types: `feat` `fix` `docs` `chore` `refactor` `test` `ci` `perf`.

EF migration'ları elle yazılmaz; `dotnet ef migrations add <Name>` kullanın. / Never hand-write EF migrations.

## Güvenlik / Security

Açıkları herkese açık issue ile bildirmeyin; bkz. [`SECURITY.md`](SECURITY.md).
