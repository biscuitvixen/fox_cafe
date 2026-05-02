#!/bin/bash
# Nightly restic backup for fox_cafe
#
# Stops Foundry containers briefly for a clean snapshot, then restarts them
# via a trap so they always come back up even if restic fails.
#
# Two-stage backup:
#   1. restic → local repo on VPS disk (always runs, fast)
#   2. rsync  → NFS mount over Tailscale (best-effort, skipped if not mounted)
#
# Scheduled at 09:00 UTC daily via systemd timer:
#   - US West Coast: 02:00 PDT
#   - US East Coast: 05:00 EDT
#   - UK:            10:00 BST
#   - EU Central:    11:00 CEST
#
# Prerequisites:
#   1. restic installed on the host
#   2. /etc/restic/fox-cafe.env created (see backup/README.md)
#   3. Repo initialised: RESTIC_REPOSITORY=/var/backups/fox-cafe restic --password-file /etc/restic/fox-cafe.env init
#   4. NFS mount configured in /etc/fstab (see backup/README.md)
#   5. systemd timer enabled: systemctl enable --now backup-fox-cafe.timer

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESTIC_REPOSITORY=/var/backups/fox-cafe
export RESTIC_REPOSITORY

# Stop Foundry containers - Caddy and monitoring stay up
docker compose -f "$COMPOSE_DIR/docker-compose.yml" stop foundry-beastworld foundry-test

# Always restart on exit, whether backup succeeded, failed, or was killed
trap 'docker compose -f "$COMPOSE_DIR/docker-compose.yml" start foundry-beastworld foundry-test' EXIT

restic backup \
  "$COMPOSE_DIR/data/foundry-beastworld/Data" \
  "$COMPOSE_DIR/data/foundry-beastworld/Config" \
  "$COMPOSE_DIR/data/foundry-test/Data" \
  "$COMPOSE_DIR/data/foundry-test/Config" \
  "$COMPOSE_DIR/data/caddy/data" \
  --exclude "*/container_cache" \
  --exclude "*/Logs" \
  --tag fox-cafe

restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --prune \
  --tag fox-cafe

# Sync local repo to NFS (best-effort - non-fatal if NAS is unavailable)
# TODO: uncomment once NAS is reachable over Tailscale (see backup/README.md)
# if mountpoint -q /mnt/tailscale-nas; then
#     rsync -a --delete /var/backups/fox-cafe/ /mnt/tailscale-nas/fox-cafe/ \
#       || echo "WARNING: NAS rsync failed - local backup still intact"
# else
#     echo "WARNING: /mnt/tailscale-nas not mounted - skipping NAS sync"
# fi
