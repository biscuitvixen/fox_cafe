# TODO

## Backup failure notifications via Uptime Kuma

Add a push monitor for the nightly backup job so failures are surfaced
immediately rather than discovered at restore time.

- Add a success ping at the end of `backup.sh` (HTTP GET to the push
  monitor URL stored in `fox-cafe.env`).
- Add an `ERR` trap at the top of `backup.sh` that pushes `status=down`
  on any unhandled error.
- Create the push monitor in Uptime Kuma and set a heartbeat interval
  slightly longer than the expected backup window.

## Move public assets to assets.bluefox.cafe

Current model: `/css/*`, `/fonts/*`, `/shared/*` are served via the
`(public_assets)` snippet's `handle_path` blocks on every gated
subdomain. These run before the `authorize` directive, so the asset
trees are effectively a public CDN attached to every hostname. Anyone
adding a file under those paths in the Hugo build publishes it
publicly, including from gated subdomain URLs. Today the only control
is a README warning in the Hugo repo.

Replace with a dedicated `assets.bluefox.cafe` subdomain that owns the
public asset trees. Gated subdomains stop importing `public_assets` and
have no auth-bypassing handlers, their roots become pure gated content.

There's also a concrete collision that motivates this move: Foundry's
client serves its own CSS at `/css/*` and fonts at `/fonts/*`, which
overlap with the apex paths the `(public_assets)` snippet handles. As a
stopgap, `(gated_proxy_site)` only passes `/shared/*` through to the
apex build and lets `/css/*` and `/fonts/*` flow to the upstream. Any
future proxied upstream that also exposes `/shared/*` would hit the
same class of problem. Moving public assets to a dedicated subdomain
removes the overlap entirely.

Steps:

- Add an `assets.bluefox.cafe { ... }` site block in `caddy/Caddyfile`
  rooted at `/srv/bluefox.cafe/current/{shared,css,fonts}` (or restructure
  the Hugo output so `assets/` is one tree). Public, no auth.
- Set `Access-Control-Allow-Origin: *` (or scope to `*.bluefox.cafe`) so
  cross-origin font / CSS fetches work from gated subdomains, and add
  `crossorigin` to the `<link>` / `<script>` tags Hugo emits.
- Drop `import public_assets` from `gated_static_site`,
  `gated_proxy_site`, `kuma`, `logs`, the `*.bluefox.cafe` catchall.
  Delete the `(public_assets)` snippet.
- Update Hugo's `layouts/_default/baseof.html` (and any partial that
  emits asset URLs) to point at `https://assets.bluefox.cafe/...` in
  prod. Add a `params.devUrls` entry so `hugo server` keeps using local
  paths.
- Confirm the wildcard cert covers `assets.bluefox.cafe` (it should -
  DNS-01 wildcard already in place).
- Bot link-preview pages at `/previews/<name>/` stay where they are -
  they're served from the gated subdomain itself with a UA-matched
  bypass and don't belong on the asset host.

## Add client-IP headers to reverse_proxy blocks

Caddy's defaults send `X-Forwarded-For` / `X-Forwarded-Proto` /
`X-Forwarded-Host` and pass the original `Host` through, but don't set
`X-Real-IP`. Several apps prefer `X-Real-IP` for their own access /
audit / ban logging over parsing `X-Forwarded-For` themselves.

Plan was: add a `(proxy_headers)` snippet that sets `X-Real-IP
{client_ip}` and import it inside every `reverse_proxy { ... }` block
(`gated_proxy_site` covering demiplane / beastworld / files, plus the
inline blocks for kuma and logs).

Holding off until we confirm what each upstream actually needs:

- **Foundry** (demiplane, beastworld, test): needs `proxySSL: true` and
  `trustedProxies` set in each instance's `options.json` for its audit
  log + invite-link / world URLs to reflect real client IPs and the
  outer https scheme. Without that, sending `X-Real-IP` from Caddy is
  cosmetic. Verify what's in the current Foundry configs (under each
  game's data dir) and whether the trusted-proxies list correctly
  covers the Caddy container's IP range on the compose network.
- **filebrowser**: honors `X-Forwarded-For` out of the box for its
  activity log; check whether the current logs show the Caddy container
  IP (`172.x.x.x`) or real client IPs.
- **uptime-kuma**: reads `X-Forwarded-For` directly for monitor /
  notification source attribution. Probably fine as-is.
- **dozzle**: doesn't care about client IPs (it shows container logs).

Once those are checked, decide whether to add the snippet at all and
which blocks to import it into.

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

## Verify crowdsec coverage of `/auth/*`

Caddy has no in-process rate limit on the auth portal. The pinned
authcrunch image doesn't include `caddy-ratelimit`; adding it would
mean abandoning the upstream image and building Caddy via `xcaddy`
with both plugins compiled in — non-trivial ongoing maintenance.

The chosen mitigation is layered:

1. **Discord** rate-limits the OAuth callback at its end. There's no
   password bruteforce surface on our portal (Discord owns credential
   validation); the worst an attacker can do is "fill our logs / chew
   CPU."
2. **crowdsec** in the compose stack runs `crowdsecurity/caddy` +
   `crowdsecurity/http-cve` collections against the JSON access log
   and bans abusive sources at iptables via the firewall bouncer.

Before declaring this done, verify what crowdsec actually catches:

- Run `docker compose exec crowdsec cscli scenarios list` and confirm
  the loaded scenarios include something like
  `crowdsecurity/http-bf-wordpress_bf`, `crowdsecurity/http-probing`,
  and `crowdsecurity/http-crawl-non_statics`. Identify which of these
  (if any) would actually trigger on a flood of requests to `/auth/*`.
- Hit `/auth/*` with a burst from a test machine (e.g. ~200 reqs over
  10s) and check `cscli decisions list` for an active ban. If nothing
  fires, the layered claim is wishful thinking.
- If coverage is weak, the options are: (a) write a custom crowdsec
  scenario tuned for our auth paths, or (b) bite the bullet and build
  a combined `xcaddy` image with caddy-security + caddy-ratelimit.
  Prefer (a).

Until verified, the "rate limiting is handled" claim above the auth
site block in `caddy/Caddyfile` is aspirational, not load-tested.

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
