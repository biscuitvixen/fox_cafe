# Backup

Containers are paused briefly each night for a clean restic snapshot, then
resumed unconditionally via a shell trap. Caddy and Dozzle stay up throughout;
the Foundry games, filebrowser, crowdsec and Uptime Kuma are paused. Kuma is in
that list both so its SQLite db is snapshotted with no writer attached and so it
doesn't poll the other paused containers and alert on them.

Two-stage design:
1. **restic → local repo** on the VPS (`$LOCAL_REPOSITORY`) - always runs, fast, works offline
2. **restic copy → NFS mount** over Tailscale (`$REMOTE_REPOSITORY` under `$REMOTE_MOUNT`) - best-effort offsite copy, skipped cleanly if the remote is unavailable. Uses `restic copy` (not rsync) so the remote holds an independent restic repo with shared chunker params, preserving dedup across both repos.

All paths are configured via the env file in step 3 below, loaded by the script and systemd unit.

## Schedule

09:00 UTC daily (02:00 PDT / 05:00 EDT / 10:00 BST / 11:00 CEST).

## What is backed up

| Path | Contents | Why |
|------|----------|-----|
| `data/foundry-demiplane/Data` | Worlds, modules, assets, systems | Irreplaceable campaign data |
| `data/foundry-demiplane/Config` | License, options | Quick to recreate, but handy |
| `data/foundry-beastworld/Data` | Same | Same |
| `data/foundry-beastworld/Config` | Same | Same |
| `data/caddy/data` | ACME certs + state | Let's Encrypt rate-limits re-issuance to 5/week per domain - losing this is painful |
| `data/filebrowser` | Filebrowser DB + settings | User accounts, scopes, share links |
| `data/uptime-kuma` | Monitors, notifications, status pages, push tokens | A rebuilt Kuma mints a new push token, which then has to be reconciled with `KUMA_PUSH_URL` by hand |
| `.env` | Discord OAuth creds, JWT key, Foundry licenses | Required to start the stack. Same security boundary as the restic password file (both plaintext on host) so no extra exposure. |

Not backed up: `container_cache/`, `Logs/`.

## Setup

### 1. Install restic

```bash
apt install restic   # or: https://restic.net
```

### 2. Create the local repo directory

```bash
sudo mkdir -p <local-repo-path>   # e.g. /var/backups/fox-cafe
```

### 3. Create the env file

Holds the encryption password and the repo paths. Loaded by systemd as an `EnvironmentFile`, so it must be in `KEY=VAL` format.

```bash
sudo mkdir -p /etc/restic
sudo tee /etc/restic/fox-cafe.env > /dev/null <<EOF
RESTIC_PASSWORD=your-strong-password-here
LOCAL_REPOSITORY=<local-repo-path>
REMOTE_MOUNT=<remote-mount-point>
REMOTE_REPOSITORY=<remote-mount-point>/<repo-subdir>
KUMA_PUSH_URL=http://127.0.0.1:3001/api/push/<push-token>
EOF
sudo chmod 600 /etc/restic/fox-cafe.env
```

`KUMA_PUSH_URL` is the Uptime Kuma push monitor endpoint (see [Failure
notifications](#failure-notifications) below). It holds a secret token, which is
why it lives here rather than in the repo. Leave it out and the heartbeat is
silently skipped; the backup itself is unaffected. Note the URL is the base
endpoint with **no query string** - `backup.sh` appends `status`/`msg`/`ping`
itself.

Example values: `LOCAL_REPOSITORY=/var/backups/fox-cafe`, `REMOTE_MOUNT=/mnt/<remote-name>`, `REMOTE_REPOSITORY=/mnt/<remote-name>/fox-cafe`.

`backup.sh` exports `RESTIC_REPOSITORY="$LOCAL_REPOSITORY"` so restic itself sees the local repo by default; the remote repo is passed explicitly via `-r "$REMOTE_REPOSITORY"` only at copy/restore time.

### 4. Initialise the local repository

```bash
. /etc/restic/fox-cafe.env
restic -r "$LOCAL_REPOSITORY" init
```

### 5. Configure the NFS mount

Prerequisites on the remote NFS server:
- Tailscale running directly on the server (not via a subnet router) so it has its own tailnet IP. This avoids subnet-router SNAT and lets the NFS export ACL pin to the VPS's `/32`.
- A dedicated dataset for fox-cafe backups with an NFS export configured `all_squash` to a dedicated UID/GID (so VPS root writes land as a single backup identity on the remote, distinct from any other share).
- Authorized Networks on the export set to the VPS's tailnet IP `/32`.

Install NFS client tools and add to `/etc/fstab` (substitute your remote tailnet IP / MagicDNS name and export path):

```
<remote-tailnet-ip>:/mnt/<pool>/fox-cafe-backups  <remote-mount-point>  nfs  _netdev,nofail,soft,timeo=30,vers=4  0 0
```

(`/etc/fstab` is read before env files are sourced, so the mount point must be the literal path you set as `REMOTE_MOUNT` in the env file.)

- `_netdev` - wait for network before mounting at boot
- `nofail` - don't halt boot if the remote is unreachable
- `soft,timeo=30` - time out cleanly rather than hanging if the remote disappears mid-transfer
- `vers=4` - pin to NFSv4 (single port 2049, simpler firewall story than v3)

Create the mount point and test:
```bash
sudo apt install nfs-common
. /etc/restic/fox-cafe.env
sudo mkdir -p "$REMOTE_MOUNT"
sudo mount "$REMOTE_MOUNT"
mountpoint -q "$REMOTE_MOUNT" && echo "mounted OK"
sudo touch "$REMOTE_MOUNT/.write-test" && sudo rm "$REMOTE_MOUNT/.write-test"
```

The write test confirms the squash UID owns the dataset; if it fails, re-check dataset ownership matches the export's `anonuid`/`anongid`.

### 5a. Initialise the remote-side restic repo

The two restic repos must share chunker params for dedup to carry across. Initialise the destination with `--copy-chunker-params` pointing at the existing local repo:

```bash
. /etc/restic/fox-cafe.env
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"
restic -r "$REMOTE_REPOSITORY" init \
  --copy-chunker-params --from-repo "$LOCAL_REPOSITORY"
```

After this, the nightly `restic copy` step in `backup.sh` only ships new pack files each run.

### 6. Make the script executable

```bash
chmod +x /home/biscuit/fox_cafe/prod/backup/backup.sh
```

### 7. Install the systemd units

Create `/etc/systemd/system/backup-fox-cafe.service`:
```ini
[Unit]
Description=Fox Cafe restic backup
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/fox-cafe.env
ExecStart=/home/biscuit/fox_cafe/prod/backup/backup.sh
User=root
```

Create `/etc/systemd/system/backup-fox-cafe.timer`:
```ini
[Unit]
Description=Daily Fox Cafe backup at 09:00 UTC

[Timer]
OnCalendar=*-*-* 09:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now backup-fox-cafe.timer
```

## Failure notifications

`backup.sh` reports each run to an Uptime Kuma **push** monitor ("Nightly
Backup"), which alerts to Discord if a heartbeat fails to arrive.

- **Success**: pushes `status=up` at the end of the run. The backup's wall-clock
  duration is sent as the monitor's `ping`, so Kuma graphs how long backups take
  and you can see the trend creeping up before it becomes a problem.
- **Failure**: an `ERR` trap pushes `status=down` with the failing line number
  and command. The container-unpause `EXIT` trap still runs afterwards, so a
  failed backup never leaves Foundry paused.
- **Degraded**: a failed forget/prune or a skipped offsite copy is not fatal (by
  design, see the script comments), so the run still pushes `up`, but the
  warnings ride along in the message. A persistently unmounted NFS share shows
  as `OK, degraded: [offsite skipped: not mounted]` in the Kuma UI rather than
  hiding behind a green tick.

The monitor's heartbeat interval is **90000s (25 hours)**, not 24. The interval
is a deadline measured from the last heartbeat, and the heartbeat fires when the
backup *finishes*, so its clock time drifts with backup duration. At exactly 24h
a run that takes 30 minutes longer than the previous one trips a false alarm.
The extra hour absorbs that drift, so a genuine miss alerts around 10:00 UTC.

Kuma is reached over `127.0.0.1:3001`, published loopback-only by the
`uptime-kuma` service in `docker-compose.yml`. The public
`https://kuma.bluefox.cafe/api/push/...` URL that the Kuma UI shows you does
**not** work from here: that host imports `gated_admin`, so every path including
`/api/push/*` is behind the Discord auth gate and a push gets a 302 to the auth
portal. That failure is quiet in the worst way, because `curl` treats a 302 as
success, so the script would report a clean run while the heartbeat never
arrives and the monitor goes down 25 hours later blaming restic.

Ignore the `docker run ... louislam/uptime-kuma:push` snippet the UI offers.
That is an unconditional `while true; curl; sleep` loop, so it reports OK
whether or not the backup worked. It monitors host liveness, not job outcome.

To test the wiring by hand:

```bash
. /etc/restic/fox-cafe.env
curl -fsS -G "$KUMA_PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=manual test"
```

### If pushes start returning 404

The push route's only documented 404 is "Monitor not found or not active", so a
404 reads like a bad or revoked token. It can also mean something else entirely.
Check the response body, which `-o /dev/null` would otherwise hide:

```bash
. /etc/restic/fox-cafe.env
curl -s -G "$KUMA_PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=probe"
```

If it contains a `stat_daily` constraint error:

```
{"ok":false,"msg":"insert into `stat_daily` ... SQLITE_CONSTRAINT:
 UNIQUE constraint failed: stat_daily.monitor_id, stat_daily.timestamp"}
```

then Kuma is trying to insert a daily stats row that already exists, rather than
update it. Two concurrent writes to the same monitor's daily bucket get it into
this state, and it then rejects **every** push until restarted:

```bash
docker compose restart uptime-kuma
```

The database is fine; the bad state is in memory, and a restart clears it. Kuma
keeps serving normally throughout, so its healthcheck and every other endpoint
stay green while only pushes fail.

Observed once, on 2026-07-24, when a request issued while Kuma was paused sat in
the socket backlog and was processed on unpause at the same moment as a second
push. That is a plausible shape for the nightly pause window, though a real one
drains status-page reads, which write no stats. If it recurs, the give-away is a
`WARNING: Kuma push (up) failed` line in `journalctl -u backup-fox-cafe` on a run
that otherwise succeeded, followed ~25h later by a "backup missed" alert blaming
restic for a Kuma fault.

## Verify

Check the timer is scheduled:
```bash
systemctl list-timers backup-fox-cafe
```

Check last run status and logs:
```bash
sudo systemctl status backup-fox-cafe
sudo journalctl -u backup-fox-cafe -n 50
```

Note: `sudo` is required because the service runs as root (needed to read
`data/caddy/data/` which is root-owned by the Caddy container). Without it,
journalctl shows `-- No entries --`.

List snapshots (via the CLI wrapper - it sources the env file for you):
```bash
sudo backup/backup-cli.sh snapshots            # local repo
sudo backup/backup-cli.sh snapshots --remote   # remote repo
```

## Manual operations

`backup-cli.sh` is a thin wrapper around the same `lib.sh` that the nightly
job uses, so manual runs use identical paths, container set, retention
policy, and nice/ionice tuning. Useful for ad-hoc backups, dry runs before
changing the schedule, and pre-restore inspection.

Run with `sudo` (needs to read `/etc/restic/fox-cafe.env` and the
root-owned `data/caddy/data/`).

Interactive menu:
```bash
sudo backup/backup-cli.sh menu
```

Single commands:
```bash
sudo backup/backup-cli.sh backup           # pause containers, backup, unpause
sudo backup/backup-cli.sh forget           # apply retention policy + prune
sudo backup/backup-cli.sh copy             # mirror local repo to remote
sudo backup/backup-cli.sh snapshots        # list snapshots (add --remote for the remote repo)
sudo backup/backup-cli.sh check            # verify repo integrity
sudo backup/backup-cli.sh stats            # repo size / dedup stats
sudo backup/backup-cli.sh unlock           # remove stale repo locks
sudo backup/backup-cli.sh pause            # pause containers only
sudo backup/backup-cli.sh unpause          # unpause containers only
```

Dry-run flags:
```bash
sudo backup/backup-cli.sh backup --dry-run   # backup with no writes (also skips pause/unpause)
sudo backup/backup-cli.sh forget --dry-run   # show what forget+prune would remove
sudo backup/backup-cli.sh copy --dry-run     # show what copy would ship
sudo backup/backup-cli.sh dry-run            # full pipeline dry-run (backup+forget+copy)
```

### Tags and retention

Every snapshot carries `fox-cafe`. On top of that:

- **Nightly** snapshots (from the systemd job) are tagged `nightly`.
- **Manual** snapshots (from `backup-cli.sh backup`) are tagged `manual`.

The retention policy in `fc_forget` is scoped to `--tag nightly`, so manual
snapshots are **never selected for forget and are kept indefinitely**. That's
deliberate: a manual snapshot is taken at a specific moment for a reason
(before a Foundry upgrade, before a destructive maintenance op), and the whole
point is to preserve that exact state until you decide otherwise.

To clean up a manual snapshot when you no longer need it, forget it
explicitly by ID:

```bash
sudo backup/backup-cli.sh snapshots                                  # find the ID
sudo bash -c '. /etc/restic/fox-cafe.env && restic forget <id> --prune'
```

Retention also uses `--group-by host,tags` so all nightly snapshots pool into
a single bucket regardless of which paths they covered. Without this, any
change to the path list (renaming a foundry server, adding/removing a
service, moving the data dir) would start a new restic group that retention
treats independently, producing orphan single-snapshot groups that never age
out.

## Restore

Source the env file and target the local repo by exporting `RESTIC_REPOSITORY`:
```bash
. /etc/restic/fox-cafe.env
export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"
```

Restore a specific world to a temp location for inspection:
```bash
restic restore latest \
  --target /tmp/fox-cafe-restore \
  --include "/home/biscuit/fox_cafe/prod/data/foundry-beastworld/Data/worlds"
# Files land at: /tmp/fox-cafe-restore/home/biscuit/fox_cafe/prod/data/foundry-beastworld/Data/worlds/
```

Restore one game entirely (stop it first):
```bash
docker compose -f /home/biscuit/fox_cafe/prod/docker-compose.yml stop foundry-beastworld
restic restore latest \
  --target / \
  --include "/home/biscuit/fox_cafe/prod/data/foundry-beastworld"
docker compose -f /home/biscuit/fox_cafe/prod/docker-compose.yml start foundry-beastworld
```

Restore from a specific snapshot instead of `latest`:
```bash
restic snapshots          # find the snapshot ID
restic restore abc12345 --target / --include "/home/biscuit/fox_cafe/prod/data/foundry-beastworld"
```

Full restore after VPS rebuild (restore from remote copy if local repo is gone):
```bash
. /etc/restic/fox-cafe.env
restic -r "$REMOTE_REPOSITORY" restore latest --target /
```
