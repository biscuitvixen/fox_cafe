# TODO

## Scheduled JWT signing-key rotation

Tokens already self-expire after 7 days (`cookie lifetime 604800` in
the authcrunch `authentication portal foundryauth` block), so this
isn't about session length. It's a defence-in-depth backstop: if
`JWT_SHARED_KEY` ever leaks silently (committed `.env`, exfiltrated
backup, ex-collaborator's laptop), an attacker with the key can forge
tokens with any role - including `authp/admin` - without going
through Discord OAuth. Periodic rotation forces a leaked key to go
stale before it gets used.

Two pieces:

1. **Rotation runbook** (one-off doc). Short markdown - probably a
   new section in `caddy/SECURITY.md` or `docs/` covering:
   - When to rotate manually (suspected leak; you just kicked
     someone from the Discord guild and want them locked out now
     rather than up to 7 days later; you changed an ACL/role
     transform and want it to apply immediately).
   - The one command: `openssl rand -hex 32`, replace
     `JWT_SHARED_KEY` in `.env`, `docker compose up -d caddy`.
   - The expected effect: every existing session invalidates,
     everyone re-auths transparently via Discord on their next
     request (no password prompt assuming they're still signed in
     to Discord in that browser).

2. **Scheduled rotation** (cron / systemd timer / GitHub Action).
   - Cadence: 90 days is a reasonable starting point - long enough
     not to be UX-annoying, short enough that a quietly-leaked key
     has a bounded blast radius.
   - Mechanics: a small script that generates a new key, writes it
     to `.env` (sed in place), `docker compose up -d caddy`, and
     emits something to a notification channel so you know it
     happened.
   - Watch-outs: the script needs to run on the host with access to
     the `.env` and the docker socket. If `.env` is also synced
     via rsync from a workstation, the rotation has to happen on
     the deploy target, not the workstation, or the next deploy
     will clobber the new key.

If we ever move to a multi-key verification setup (kid-aware JWTs
with overlap windows) the scheduled rotation becomes seamless instead
of forcing a re-auth storm. Authcrunch v1.0.41's
`crypto key sign-verify` directive only accepts one key, so we don't
have that option today - any rotation is a hard cut.

## Refresh the dev-overlay docs ("Theme testing" in README.md)

The "Theme testing" section of `README.md` (the `caddy-dev` overlay on
`127.0.0.1:8081`) is stale, independent of the assets move:

- Its path table lists `/shared/theme.css` and `/shared/theme.js`, but
  `theme.js` was removed when theme tokens went build-time, and
  `theme.css` now ships inside the fingerprinted Hugo bundle, not at
  `/shared/`. Public assets also now live on `assets.bluefox.cafe` under
  `public_assets/`, not on per-subdomain `/shared/`.
- The overlay serves from the bind-mounted `caddy/` directories, which
  predates the Hugo migration - so `caddy-dev` may not serve the current
  build at all.

Next time the dev overlay is actually used, verify whether `caddy-dev`
still serves anything meaningful post-Hugo, then fix or remove the
section (its own commit). Not urgent - it's dev-only docs.
