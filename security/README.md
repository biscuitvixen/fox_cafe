# Security checks

Automated checks so a regression in the site's security posture fails loudly
instead of sitting undetected. This exists because the strict CSP was once
silently broken for a long time while `caddy validate` kept passing - the
lesson being that a check has to assert the **actual response** the running
server sends, not just that the config parses.

Two layers:

| Check | Where | Catches |
|---|---|---|
| `security-check.sh` (this dir) | live site, black-box | dropped/weakened CSP, missing security headers, a gated host serving `200`, broken/loosened asset CORS, asset host leaking gated trees |
| `bin/check-build.sh` (bluefox.cafe repo) | Hugo build, white-box | inline `<style>`/`style=`, an unexpected inline `<script>`, a bootstrap whose sha256 no longer matches `script-src` in the Caddyfile |

## security-check.sh

Fetches the live site and asserts headers + gating (see the script header for
the full list). Exits non-zero on any failure.

```bash
./security/security-check.sh              # checks bluefox.cafe
./security/security-check.sh bluefox.cafe # explicit
```

It runs in three places:

- **Deploy** - `deploy.sh` (bluefox.cafe) runs `bin/check-build.sh` *before*
  publishing (aborts the deploy on failure) and `security-check.sh` *after* the
  symlink flip (warns loudly; the build was already gated).
- **Timer** - a systemd timer runs it every 30 min for drift detection.
- **By hand** - after any Caddy change (`caddy reload`), run it to confirm the
  edge still behaves.

## Alerting via Uptime Kuma (same pattern as `backup/`)

If `SECURITY_PUSH_URL` is set, the script pushes `up`/`down` to an Uptime Kuma
**push** monitor, which forwards to Discord. Use the **loopback** URL, never
`https://kuma.bluefox.cafe/...` - the public one is behind the auth gate and a
push gets a `302` that `curl` reads as success (see `backup/README.md`).

1. Kuma UI (`kuma.bluefox.cafe`) -> add a **Push** monitor, name "Security
   check", heartbeat interval ~1800s + a retry, notification -> Discord.
2. Copy its push token and append to `/etc/restic/fox-cafe.env` (root, `0600`):
   ```
   SECURITY_PUSH_URL=http://127.0.0.1:3001/api/push/<push-token>
   ```
   (Same file the backup job uses; note a rebuilt Kuma mints new tokens.)

## Install the systemd units

Units are not tracked in the repo (same convention as `backup/`). Create them
under `/etc/systemd/system/`.

`security-check.service` (runs as the unprivileged user; systemd still injects
the root-owned `EnvironmentFile`):
```ini
[Unit]
Description=bluefox.cafe edge security check
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/fox-cafe.env
ExecStart=/home/biscuit/fox_cafe/prod/security/security-check.sh
User=biscuit
```

`security-check.timer`:
```ini
[Unit]
Description=Run the bluefox.cafe security check every 30 min

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now security-check.timer
sudo systemctl start security-check.service   # run once now
systemctl list-timers security-check.timer
```

## GitHub Actions

`bin/check-build.sh` also runs on every push/PR to the bluefox.cafe repo
(`.github/workflows/ci.yml`) as a pre-merge net. The Caddyfile isn't present
there, so the hash cross-check is skipped; the on-host deploy gate is the
authoritative one.

## Testing that it catches regressions

- `script-src` back to `'unsafe-inline'` + `caddy reload` -> `security-check.sh`
  fails the CSP assertion. Revert + reload.
- Add an inline `style=`/`<script>` to a layout + rebuild -> `check-build.sh`
  fails. Revert.
- The hash guard: edit the pre-paint bootstrap in `baseof.html` without
  updating `script-src`'s `sha256-` -> `check-build.sh` fails at deploy.

## Not covered here

Periodic external deep scans (Mozilla Observatory grade, `testssl.sh`,
`nuclei`) would add breadth but more noise; a candidate for a second, weekly
timer later.
