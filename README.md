# bluefox.cafe Foundry stack

Hosting D&D Foundry instances behind Discord OAuth, on Hetzner CPX33 (atlas).

## Layout

- `docker-compose.yml` - Docker Compose stack
- `overlays/` - per-environment port overlays (`prod.yml`, etc.)
- `caddy/Caddyfile` - reverse proxy + auth config
- `data/` - bind-mounted state for every service (gitignored)
- `.env` - secrets (NOT committed)
- `.env.example` - template

## Deploy

```bash
cp .env.example .env  # fill in values, including COMPOSE_FILE for your environment
chmod 600 .env
docker compose pull
docker compose up -d
docker compose logs -f caddy   # watch ACME issue real certs
```

### Environment overlays

Ports are not published in the base `docker-compose.yml`. Each worktree's `.env`
sets `COMPOSE_FILE` to merge the appropriate overlay:

| Worktree | `COMPOSE_FILE` value |
|----------|----------------------|
| `prod`    | `docker-compose.yml:overlays/prod.yml` |
| `staging` | `docker-compose.yml:overlays/staging.yml` |
| `dev`     | `docker-compose.yml` |

`overlays/prod.yml` publishes ports 80, 443, and 443/udp on the host.
Create equivalent overlay files for staging/dev as needed (e.g. 8080/8443).

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
     `demiplane_policy`).
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
- Container updates: all images are pinned. Bump tags manually after reading
  release notes (especially Caddy/authcrunch and Foundry).
- Manual update: `docker compose pull && docker compose up -d`

### Rotating the JWT signing key

`JWT_SHARED_KEY` signs the session cookies issued by the auth portal. Rotate
it if you suspect leakage, after a contributor with `.env` access leaves, or
periodically as hygiene.

caddy-security only loads one key at a time - there is no graceful overlap.
Rotation invalidates every existing session; all users redirect to Discord
once and re-auth. No data is lost.

```bash
# 1. Generate a new key
openssl rand -hex 32

# 2. Replace JWT_SHARED_KEY in .env
# 3. Restart caddy to pick it up
docker compose up -d caddy
```

Foundry game sessions (the in-app websocket) survive the cookie invalidation
as long as the browser tab stays open; only the next navigation hits the auth
gate.

### CrowdSec

A CrowdSec agent runs in the stack, parses Caddy's JSON access log
(`caddy_logs` named volume), and exposes LAPI on `127.0.0.1:8080`. A host-side
**`crowdsec-firewall-bouncer-nftables`** systemd service polls LAPI every 10s
and maintains `table ip crowdsec` / `table ip6 crowdsec6` in nftables - drops
happen before Docker's DNAT, so banned IPs never reach Caddy.

The instance is enrolled in the CrowdSec console (https://app.crowdsec.net)
for the community blocklist push and a remote dashboard. State lives at
`./data/crowdsec/{data,config}` and is picked up by the nightly backup.

```bash
# What's currently banned, and why
docker compose exec crowdsec cscli decisions list

# Recent scenarios that fired
docker compose exec crowdsec cscli alerts list

# Unban an IP (e.g. yourself after a false positive)
docker compose exec crowdsec cscli decisions delete --ip <ip>

# Confirm the host bouncer is connected and pulling
docker compose exec crowdsec cscli bouncers list
sudo systemctl status crowdsec-firewall-bouncer

# Console + CAPI status (enrolment, signal sharing, blocklist subscriptions)
docker compose exec crowdsec cscli console status
docker compose exec crowdsec cscli capi status

# Inspect the kernel-level blocklist
sudo nft list table ip crowdsec
```

If the bouncer dies, existing nftables rules stay in place (no protection
lost) but no new decisions get enforced until it restarts:
`sudo systemctl restart crowdsec-firewall-bouncer`.

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
- https://demiplane.bluefox.cafe - Demiplane campaign (Demiplane guild + admin)
- https://beastworld.bluefox.cafe - Beastworld campaign (Demiplane guild + admin)
- https://test.bluefox.cafe - sandbox Foundry (admin only)
- https://kuma.bluefox.cafe - uptime monitoring (admin only)
- https://logs.bluefox.cafe - container logs (admin only)

## Auth model

One Discord login produces one JWT cookie at the apex (`.bluefox.cafe`) that
covers every subdomain. What the cookie *unlocks* depends on which roles the
user has - the cookie is the same, the authorization differs per site.

Roles assigned by the Caddyfile transforms:

- `authp/guild_demiplane` - set if the user is in the Demiplane Discord guild
  (currently gates both Demiplane and Beastworld)
- `authp/member`          - set if the user is in any gating guild
- `authp/admin`           - set if the user's Discord ID matches `DISCORD_ADMIN_USER_ID`
- `authp/user`            - set on every Discord login (compatibility for authcrunch internals; not used for service authorization)

Scaffolding for a second guild (`DISCORD_GUILD_EXAMPLE_2` → `authp/guild_example_2`)
is present in the Caddyfile but commented out - activate the transform,
`user_group_filters` entry, and policy together when adding a second guild.

Policies (one per access tier):

- `dnd_policy`       - `authp/member` or `authp/admin`
- `demiplane_policy` - `authp/guild_demiplane` or `authp/admin` (gates demiplane + beastworld)
- `admin_policy`     - `authp/admin` only