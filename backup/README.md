# Backup

Foundry game containers are stopped briefly each night for a clean restic
snapshot, then restarted unconditionally via a shell trap. Caddy, Uptime Kuma,
and Dozzle stay up throughout - only the game servers are paused.

Two-stage design:
1. **restic → local repo** on the VPS (`$LOCAL_REPOSITORY`) - always runs, fast, works offline
2. **restic copy → NFS mount** over Tailscale (`$REMOTE_REPOSITORY` under `$REMOTE_MOUNT`) - best-effort offsite copy, skipped cleanly if the remote is unavailable. Uses `restic copy` (not rsync) so the remote holds an independent restic repo with shared chunker params, preserving dedup across both repos.

All paths are configured via the env file in step 3 below, loaded by the script and systemd unit.

## Schedule

09:00 UTC daily (02:00 PDT / 05:00 EDT / 10:00 BST / 11:00 CEST).

## What is backed up

| Path | Contents | Why |
|------|----------|-----|
| `data/foundry-beastworld/Data` | Worlds, modules, assets, systems | Irreplaceable campaign data |
| `data/foundry-beastworld/Config` | License, options | Quick to recreate, but handy |
| `data/foundry-starwars/Data` | Same | Same |
| `data/foundry-starwars/Config` | Same | Same |
| `data/caddy/data` | ACME certs + state | Let's Encrypt rate-limits re-issuance to 5/week per domain - losing this is painful |
| `data/filebrowser` | Filebrowser DB + settings | User accounts, scopes, share links |
| `.env` | Discord OAuth creds, JWT key, Foundry licenses | Required to start the stack. Same security boundary as the restic password file (both plaintext on host) so no extra exposure. |

Not backed up: `data/uptime-kuma` (monitor config, easily recreated),
`container_cache/`, `Logs/`.

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
EOF
sudo chmod 600 /etc/restic/fox-cafe.env
```

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
