# Backup

Foundry game containers are stopped briefly each night for a clean restic
snapshot, then restarted unconditionally via a shell trap. Caddy, Uptime Kuma,
and Dozzle stay up throughout - only the game servers are paused.

Two-stage design:
1. **restic → local repo** at `/var/backups/fox-cafe/` on the VPS - always runs, fast, works offline
2. **rsync → NFS mount** at `/mnt/tailscale-nas/` over Tailscale - best-effort offsite copy, skipped cleanly if the NAS is unavailable

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

Not backed up: `data/uptime-kuma` (monitor config, easily recreated),
`container_cache/`, `Logs/`.

## Setup

### 1. Install restic

```bash
apt install restic   # or: https://restic.net
```

### 2. Create the local repo directory

```bash
sudo mkdir -p /var/backups/fox-cafe
```

### 3. Create the credentials file

Only the encryption password goes here - the repository path is set in the script.

```bash
sudo mkdir -p /etc/restic
sudo tee /etc/restic/fox-cafe.env > /dev/null <<EOF
RESTIC_PASSWORD=your-strong-password-here
EOF
sudo chmod 600 /etc/restic/fox-cafe.env
```

### 4. Initialise the local repository

```bash
RESTIC_REPOSITORY=/var/backups/fox-cafe \
  restic --password-file /etc/restic/fox-cafe.env init
```

### 5. Configure the NFS mount

Add to `/etc/fstab` (adjust the NAS hostname/IP and export path for your setup):

```
nas-hostname:/backups  /mnt/tailscale-nas  nfs  _netdev,nofail,soft,timeo=30  0 0
```

- `_netdev` - wait for network before mounting at boot
- `nofail` - don't halt boot if the NAS is unreachable
- `soft,timeo=30` - time out cleanly rather than hanging if the NAS disappears mid-transfer

Create the mount point and test:
```bash
sudo mkdir -p /mnt/tailscale-nas
sudo mount /mnt/tailscale-nas
mountpoint -q /mnt/tailscale-nas && echo "mounted OK"
```

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

List snapshots:
```bash
RESTIC_REPOSITORY=/var/backups/fox-cafe \
  restic --password-file /etc/restic/fox-cafe.env snapshots
```

## Restore

Set a shell alias for convenience:
```bash
alias restic-fc='RESTIC_REPOSITORY=/var/backups/fox-cafe restic --password-file /etc/restic/fox-cafe.env'
```

Restore a specific world to a temp location for inspection:
```bash
restic-fc restore latest \
  --target /tmp/fox-cafe-restore \
  --include "/home/biscuit/fox_cafe/prod/data/foundry-beastworld/Data/worlds"
# Files land at: /tmp/fox-cafe-restore/home/biscuit/fox_cafe/prod/data/foundry-beastworld/Data/worlds/
```

Restore one game entirely (stop it first):
```bash
docker compose -f /home/biscuit/fox_cafe/prod/docker-compose.yml stop foundry-beastworld
restic-fc restore latest \
  --target / \
  --include "/home/biscuit/fox_cafe/prod/data/foundry-beastworld"
docker compose -f /home/biscuit/fox_cafe/prod/docker-compose.yml start foundry-beastworld
```

Restore from a specific snapshot instead of `latest`:
```bash
restic-fc snapshots          # find the snapshot ID
restic-fc restore abc12345 --target / --include "/home/biscuit/fox_cafe/prod/data/foundry-beastworld"
```

Full restore after VPS rebuild (restore from NAS copy if local repo is gone):
```bash
RESTIC_REPOSITORY=/mnt/tailscale-nas/fox-cafe \
  restic --password-file /etc/restic/fox-cafe.env restore latest --target /
```
