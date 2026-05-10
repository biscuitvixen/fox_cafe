#!/bin/bash
# Nightly restic backup for fox_cafe
#
# Pauses Foundry containers briefly for a clean snapshot, then unpauses them
# via a trap so they always come back up even if restic fails.
#
# Two-stage backup:
#   1. restic → local repo on VPS disk (always runs, fast)
#   2. restic copy → NFS mount over Tailscale (best-effort, skipped if not mounted)
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
#   3. Repo initialised: . /etc/restic/fox-cafe.env && restic init
#   4. NFS mount configured in /etc/fstab (see backup/README.md)
#   5. systemd timer enabled: systemctl enable --now backup-fox-cafe.timer

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# LOCAL_REPOSITORY, REMOTE_MOUNT, and REMOTE_REPOSITORY are loaded from
# /etc/restic/fox-cafe.env via systemd EnvironmentFile. Restic itself reads
# RESTIC_REPOSITORY, so we mirror LOCAL_REPOSITORY into it for the bare
# `restic backup` / `restic forget` calls below.
export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"

# Containers to pause during backup - Caddy and monitoring stay up.
# Filebrowser is included so its sqlite db is snapshotted with no writer attached.
# pause/unpause (SIGSTOP/SIGCONT) is used instead of stop/start so Docker
# doesn't treat the exit as a crash and auto-restart containers mid-backup.
CONTAINERS=(
  foundry-beastworld
  foundry-starwars
  filebrowser
)

docker compose -f "$COMPOSE_DIR/docker-compose.yml" pause "${CONTAINERS[@]}"

# Safety net: unpause on exit if we die during the backup itself
trap 'docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"' EXIT

# Run restic under nice + ionice so its disk I/O doesn't starve
# containers on the single shared sda1 volume.
#   nice -n10        : lower CPU priority (default 0, range -20..19)
#   ionice -c2 -n7   : best-effort I/O class, lowest priority within it
RESTIC_NICE=(nice -n10 ionice -c2 -n7)

"${RESTIC_NICE[@]}" restic backup \
  "$COMPOSE_DIR/data/foundry-beastworld/Data" \
  "$COMPOSE_DIR/data/foundry-beastworld/Config" \
  "$COMPOSE_DIR/data/foundry-starwars/Data" \
  "$COMPOSE_DIR/data/foundry-starwars/Config" \
  "$COMPOSE_DIR/data/filebrowser" \
  "$COMPOSE_DIR/data/caddy/data" \
  --exclude "*/container_cache" \
  --exclude "*/Logs" \
  --tag fox-cafe

# Source data is captured - bring containers back up before the slower
# repo-maintenance steps (forget/prune/copy) which only touch restic repos.
docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"
# Clear the trap since we've already unpaused
trap - EXIT

"${RESTIC_NICE[@]}" restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --keep-yearly 1 \
  --prune \
  --tag fox-cafe

# Mirror local repo to NAS via restic copy (best-effort, non-fatal if NAS is unavailable).
# Both repos share chunker params (set at NAS repo init) so dedup carries across; only
# new pack files are sent each night. RESTIC_FROM_PASSWORD covers the source (--from-repo).
if mountpoint -q "$REMOTE_MOUNT"; then
    RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
      "${RESTIC_NICE[@]}" restic -r "$REMOTE_REPOSITORY" copy \
        --from-repo "$LOCAL_REPOSITORY" \
      || echo "WARNING: NAS restic copy failed - local backup still intact"
else
    echo "WARNING: $REMOTE_MOUNT not mounted - skipping NAS copy"
fi
