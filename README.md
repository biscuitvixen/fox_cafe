# bluefox.cafe Foundry stack

Hosting D&D Foundry instances behind Discord OAuth, on Hetzner CPX33 (atlas).

## Layout

- `compose.yml` - Docker Compose stack
- `caddy/Caddyfile` - reverse proxy + auth config
- `.env` - secrets (NOT committed)
- `.env.example` - template

## Deploy

```bash
cp .env.example .env  # fill in values
chmod 600 .env
docker compose pull
docker compose up -d
docker compose logs -f caddy   # watch ACME issue real certs
```

## Adding a new game

1. Add `FOUNDRY_*_GAMENAME` env vars to `.env` and `.env.example`
2. Duplicate a `foundry-*` service block in `compose.yml`
3. Declare `foundry_gamename` volume in compose
4. Add a `gamename.bluefox.cafe { ... }` block in `Caddyfile`
5. Add Uptime Kuma monitor at `kuma.bluefox.cafe`
6. `docker compose up -d`

## Backups (TODO)

- `caddy_data` - ACME state, losing this triggers Let's Encrypt rate limits
- `foundry_*` - game state, irreplaceable
- `kuma_data` - uptime history
- `~/foundry-stack/` itself (this directory)

Restic to TrueNAS over Tailscale. See SETUP.md (TODO).

## Operations

- Logs: `docker compose logs -f <service>`, or web UI at logs.bluefox.cafe
- Health: kuma.bluefox.cafe
- Container updates: Watchtower runs daily 05:00 UTC, posts to Discord webhook
- Manual update: `docker compose pull && docker compose up -d`

## URLs

- https://bluefox.cafe - apex, redirects to auth portal
- https://auth.bluefox.cafe - Discord login
- https://starwars.bluefox.cafe - Star Wars campaign
- https://beastworld.bluefox.cafe - Beastworld campaign
- https://kuma.bluefox.cafe - uptime monitoring
- https://logs.bluefox.cafe - container logs