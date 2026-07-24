# TODO

## Add client-IP headers to reverse_proxy blocks

Caddy's defaults send `X-Forwarded-For` / `X-Forwarded-Proto` /
`X-Forwarded-Host` and pass the original `Host` through, but don't set
`X-Real-IP`. Several apps prefer `X-Real-IP` for their own access /
audit / ban logging over parsing `X-Forwarded-For` themselves.

Plan was: add a `(proxy_headers)` snippet that sets `X-Real-IP
{client_ip}` and import it inside every `reverse_proxy { ... }` block
(`gated_proxy_site` covering demiplane / beastworld / files, plus the
inline blocks for kuma and logs).

Checked 2026-07-24, and most of it turns out to be unnecessary:

- **filebrowser**: already logs real client IPs (`80.4.14.198` seen in
  its access log, not a `172.x` container address), so it honours
  `X-Forwarded-For` as expected. Nothing to do.
- **uptime-kuma**: reads `X-Forwarded-For` directly. Nothing to do.
- **dozzle**: doesn't care about client IPs (it shows container logs).
- **Foundry** (demiplane, beastworld): `proxySSL: true` and
  `proxyPort: 443` are both set, but **`trustedProxies` is unset on
  both**. Until it is, Foundry ignores the forwarded headers and sending
  `X-Real-IP` from Caddy would be cosmetic.

So this is now one decision rather than an investigation: either set
`trustedProxies` in each game's `options.json` to cover the Caddy
container's range on `foundry_web` and then add the snippet, or close
this out. Foundry's audit log is the only consumer, so closing it out is
defensible.

## Tighten CSP — drop `'unsafe-inline'`

The `(static_csp)` snippet in `caddy/Caddyfile` still allows
`'unsafe-inline'` on both `script-src` and `style-src`. After the
stale CDN allowlist entries were removed, these two are the only
remaining loosenings on the static landing pages.

Audit of what actually uses them (in the Hugo project at
~/bluefox.cafe):

- **script-src 'unsafe-inline':** required by exactly one block — the
  rotator script in `layouts/index.html` (lines 78-101). It's
  parameterized by `{{ .Params.roles | jsonify | safeJS }}` so the
  data is baked into the rendered HTML at build time, but the script
  body itself is otherwise static.
- **style-src 'unsafe-inline':** required by three static (no template
  vars) locations:
  - `layouts/index.html` — `<style>` block in `<head>` with the
    rotator CSS (`#role`, `.role-leave`, `.role-enter`).
  - `layouts/dnd/single.html:21` — `style="font-family: 'Cinzel
    Decorative', serif; letter-spacing: 0.02em;"` on the page h1.
  - `layouts/dnd/single.html:40` — `style="background:
    linear-gradient(180deg, #497bd6, #24d962); opacity: 0.7;"` on the
    accent stripe (two card instances).

Two steps, each can ship independently:

1. **Drop `'unsafe-inline'` from style-src** (smaller, easier win).
   - Move the homepage rotator `<style>` block into the Hugo asset
     pipeline so it ends up in the fingerprinted bundle.
   - Add a `.dnd-title` (or similar) class to `assets/css/theme.css`
     and remove the inline `style=` on the dnd h1.
   - Add `.dnd-card-stripe` (or similar) class to `theme.css` and
     remove the inline `style=` on the two accent stripes.
   - Edit `(static_csp)` to remove `'unsafe-inline'` from style-src.

2. **Drop `'unsafe-inline'` from script-src** (larger, optional).
   Two approaches:
   - **Refactor to data-attribute + external JS.** Put
     `data-roles="..."` on the rotator's target element, move the
     rotator logic into a static `.js` file under `assets/js/`, ship
     it through Hugo Pipes (fingerprint + minify). The script reads
     `.dataset.roles`. Cleanest, no per-build coupling between Hugo
     and Caddy. Removes 'unsafe-inline' entirely.
   - **Use `'sha256-...'` hash in the CSP.** The rendered inline
     script is deterministic per build (roles array is baked in), so
     a content hash works. Hugo can compute it via `resources.Get`
     /  `resources.FromString` + `.Data.Integrity`. But Caddy serves
     a single static CSP header for the whole site, so either the
     Caddyfile gets manually updated on every roles change, or Hugo
     emits a per-page `<meta http-equiv="Content-Security-Policy">`
     that overrides the header-level CSP for the homepage. Both
     options are clunky. Prefer the data-attribute refactor.

When both are done, the CSP becomes a real "no inline anything" policy
which meaningfully closes the XSS attack surface on the landing pages.

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
