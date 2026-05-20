# TODO

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
have no auth-bypassing handlers — their roots become pure gated content.

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
