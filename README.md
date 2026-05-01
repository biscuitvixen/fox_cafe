# bluefox.cafe Foundry stack

Hosting D&D Foundry instances behind Discord OAuth, on Hetzner CPX33 (atlas).

## Layout

- `docker-compose.yml` - Docker Compose stack
- `caddy/Caddyfile` - reverse proxy + auth config
- `data/` - bind-mounted state for every service (gitignored)
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
2. Duplicate a `foundry-*` service block in `docker-compose.yml`
   (the `./data/foundry-gamename` bind mount is created on first start)
3. Add a `gamename.bluefox.cafe { ... }` block in `Caddyfile`
4. Add Uptime Kuma monitor pointing at `http://foundry-gamename:30000`
   (see operations note below)
5. `docker compose up -d`

## Backups (TODO)

All persistent state lives under `./data/`:

- `data/caddy/data` - ACME state. Losing this triggers Let's Encrypt rate limits.
- `data/foundry-*` - game state, irreplaceable
- `data/uptime-kuma` - uptime history
- The repo itself (`docker-compose.yml`, `caddy/Caddyfile`, `.env`)

Restic to TrueNAS over Tailscale. See SETUP.md (TODO).

## Operations

- Logs: `docker compose logs -f <service>`, or web UI at logs.bluefox.cafe.
  Container json-file logs are capped at 3×10MB per service via the
  `x-logging` anchor in compose - adjust there if you need more retention.
- Health: kuma.bluefox.cafe
- Container updates: Watchtower runs daily 05:00 UTC, posts to Discord webhook.
  Caddy is excluded from auto-updates (see comment in compose) - bump its
  pinned tag manually after reading the authcrunch release notes.
- Manual update: `docker compose pull && docker compose up -d`

### Uptime Kuma monitors

When configuring monitors in Kuma, **probe the internal docker hostnames, not
the public URLs**. The public URLs sit behind the Discord auth gate, so a
public-URL monitor would always see a redirect to `auth.bluefox.cafe` and read
as "down".

Use these targets instead (they resolve over the `web` bridge network):

- Foundry games: `http://foundry-<gamename>:30000`
- Dozzle: `http://dozzle:8080`
- Caddy itself: `http://caddy:80` (or just monitor the public auth portal,
  which is the one URL that's *not* gated)

## URLs

- https://bluefox.cafe - apex, redirects to auth portal
- https://auth.bluefox.cafe - Discord login
- https://starwars.bluefox.cafe - Star Wars campaign
- https://beastworld.bluefox.cafe - Beastworld campaign
- https://kuma.bluefox.cafe - uptime monitoring
- https://logs.bluefox.cafe - container logs