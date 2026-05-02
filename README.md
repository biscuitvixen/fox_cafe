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

Each game is gated by its own Discord guild. Adding one means wiring up a new
guild → role → policy chain.

1. **Env vars** (`.env` + `.env.example`):
   - `DISCORD_GUILD_GAMENAME` (the guild ID gating this game)
   - `FOUNDRY_*_GAMENAME` if using per-game DM credentials
2. **Compose**: duplicate a `foundry-*` block in `docker-compose.yml`
   (the `./data/foundry-gamename` bind mount is created on first start). Add
   `DISCORD_GUILD_GAMENAME` to the `caddy:` `environment:` block too.
3. **Caddyfile** - three additions:
   - Add the new guild ID to `user_group_filters` in the `oauth identity
     provider discord` block.
   - Add a transform pair (game role + `authp/member`) keyed off the new
     `DISCORD_GUILD_GAMENAME`.
   - Add an `authorization policy gamename_policy` (mirror of
     `beastworld_policy`).
   - Add a `(gated_gamename)` snippet and a `gamename.bluefox.cafe { ... }`
     site block importing it.
4. **DnD page**: add a card for the new game in `caddy/dnd/index.html`.
5. **Uptime Kuma**: add a monitor pointing at `http://foundry-gamename:30000`
   (internal docker hostname - see operations note below).
6. `docker compose up -d`.

## Backups

Nightly restic snapshot at **09:00 UTC** - see [backup/README.md](backup/README.md) for
full setup instructions. The Foundry containers are stopped for the duration;
Caddy and monitoring stay up. A shell `trap` guarantees containers restart even
if restic errors.

Quick reference:
- Status: `systemctl status backup-fox-cafe`
- Logs: `journalctl -u backup-fox-cafe -n 50`
- List snapshots: `source /etc/restic/fox-cafe.env && restic snapshots`

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

- https://bluefox.cafe - public homepage (no auth)
- https://auth.bluefox.cafe - Discord login (OAuth callback)
- https://dnd.bluefox.cafe - gated landing page (any guild member)
- https://beastworld.bluefox.cafe - Beastworld campaign (Beastworld guild + admin)
- https://starwars.bluefox.cafe - Star Wars campaign (Starwars guild + admin)
- https://test.bluefox.cafe - sandbox Foundry (admin only)
- https://kuma.bluefox.cafe - uptime monitoring (admin only)
- https://logs.bluefox.cafe - container logs (admin only)

## Auth model

One Discord login produces one JWT cookie at the apex (`.bluefox.cafe`) that
covers every subdomain. What the cookie *unlocks* depends on which roles the
user has - the cookie is the same, the authorization differs per site.

Roles assigned by the Caddyfile transforms:

- `authp/guild_beastworld` - set if the user is in the Beastworld Discord guild
- `authp/guild_starwars`   - set if the user is in the Starwars Discord guild
- `authp/member`           - set if the user is in any of the above guilds
- `authp/admin`            - set if the user's Discord ID matches `DISCORD_ADMIN_USER_ID`
- `authp/user`              - set on every Discord login (compatibility for authcrunch internals; not used for service authorization)

Policies (one per access tier):

- `dnd_policy`        - `authp/member` or `authp/admin`
- `beastworld_policy` - `authp/guild_beastworld` or `authp/admin`
- `starwars_policy`   - `authp/guild_starwars` or `authp/admin`
- `admin_policy`      - `authp/admin` only