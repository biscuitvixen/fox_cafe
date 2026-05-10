#!/bin/bash
# Manual restic operations for fox_cafe.
#
# Wraps the same env, repos, and container set as backup.sh so ad-hoc work
# (snapshots, checks, on-demand backups, restore-prep) doesn't drift from the
# nightly job. Always runs interactively - no systemd, no traps you can't see.
#
# Usage:
#   sudo backup/manual.sh <command> [--dry-run] [--remote]
#   sudo backup/manual.sh menu              # interactive picker
#
# Commands:
#   backup              Pause containers, run restic backup, unpause
#   forget              Apply retention policy + prune (local repo)
#   copy                Copy local repo to remote
#   snapshots           List snapshots (default: local; --remote for remote)
#   check               Verify repo integrity (default: local; --remote for remote)
#   stats               Repo size / dedup stats (default: local; --remote for remote)
#   unlock              Remove stale repo locks (default: local; --remote for remote)
#   pause / unpause     Pause or unpause the Foundry + filebrowser containers
#   dry-run             Full pipeline with no writes (backup+forget+copy, --dry-run)
#   menu                Interactive selection
#
# Flags:
#   --dry-run           Pass --dry-run to restic where supported. For 'backup'
#                       and 'dry-run' this also skips container pause/unpause.
#   --remote            Target the remote repo instead of the local repo (where
#                       the command is repo-scoped: snapshots/check/stats/unlock).

set -euo pipefail

ENV_FILE="/etc/restic/fox-cafe.env"
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -r "$ENV_FILE" ]]; then
    echo "ERROR: cannot read $ENV_FILE (run with sudo?)" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
export RESTIC_PASSWORD LOCAL_REPOSITORY REMOTE_MOUNT REMOTE_REPOSITORY
export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"

CONTAINERS=(
  foundry-beastworld
  foundry-starwars
  filebrowser
)

BACKUP_PATHS=(
  "$COMPOSE_DIR/data/foundry-beastworld/Data"
  "$COMPOSE_DIR/data/foundry-beastworld/Config"
  "$COMPOSE_DIR/data/foundry-starwars/Data"
  "$COMPOSE_DIR/data/foundry-starwars/Config"
  "$COMPOSE_DIR/data/filebrowser"
  "$COMPOSE_DIR/data/caddy/data"
)

RESTIC_NICE=(nice -n10 ionice -c2 -n7)

DRY_RUN=0
REMOTE=0
CMD=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --remote)  REMOTE=1 ;;
            -h|--help) usage; exit 0 ;;
            *)
                if [[ -z "$CMD" ]]; then
                    CMD="$1"
                else
                    echo "ERROR: unexpected argument: $1" >&2
                    exit 2
                fi
                ;;
        esac
        shift
    done
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

target_repo() {
    if [[ "$REMOTE" -eq 1 ]]; then
        echo "$REMOTE_REPOSITORY"
    else
        echo "$LOCAL_REPOSITORY"
    fi
}

dry_flag() {
    [[ "$DRY_RUN" -eq 1 ]] && echo "--dry-run" || true
}

pause_containers() {
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" pause "${CONTAINERS[@]}"
    trap 'docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"' EXIT
}

unpause_containers() {
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"
    trap - EXIT
}

cmd_backup() {
    local dry; dry="$(dry_flag)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] skipping container pause/unpause"
    else
        pause_containers
    fi

    "${RESTIC_NICE[@]}" restic backup \
        ${dry:+$dry} \
        "${BACKUP_PATHS[@]}" \
        --exclude "*/container_cache" \
        --exclude "*/Logs" \
        --tag fox-cafe \
        --tag manual

    if [[ "$DRY_RUN" -ne 1 ]]; then
        unpause_containers
    fi
}

cmd_forget() {
    local dry; dry="$(dry_flag)"
    "${RESTIC_NICE[@]}" restic forget \
        ${dry:+$dry} \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 3 \
        --keep-yearly 1 \
        --prune \
        --tag fox-cafe
}

cmd_copy() {
    local dry; dry="$(dry_flag)"
    if ! mountpoint -q "$REMOTE_MOUNT"; then
        echo "ERROR: $REMOTE_MOUNT not mounted" >&2
        return 1
    fi
    RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
        "${RESTIC_NICE[@]}" restic -r "$REMOTE_REPOSITORY" copy \
            ${dry:+$dry} \
            --from-repo "$LOCAL_REPOSITORY"
}

cmd_snapshots() { restic -r "$(target_repo)" snapshots; }
cmd_check()     { restic -r "$(target_repo)" check; }
cmd_stats()     { restic -r "$(target_repo)" stats; }
cmd_unlock()    { restic -r "$(target_repo)" unlock; }

cmd_dry_run() {
    DRY_RUN=1
    echo "=== dry-run: backup ==="
    cmd_backup
    echo
    echo "=== dry-run: forget+prune ==="
    cmd_forget
    echo
    echo "=== dry-run: copy to remote ==="
    if mountpoint -q "$REMOTE_MOUNT"; then
        cmd_copy
    else
        echo "skipped: $REMOTE_MOUNT not mounted"
    fi
}

cmd_menu() {
    PS3="Select operation: "
    local options=(
        "backup"
        "forget+prune"
        "copy to remote"
        "snapshots (local)"
        "snapshots (remote)"
        "check (local)"
        "check (remote)"
        "stats (local)"
        "stats (remote)"
        "unlock (local)"
        "unlock (remote)"
        "pause containers"
        "unpause containers"
        "full dry-run"
        "quit"
    )
    select opt in "${options[@]}"; do
        case "$opt" in
            "backup")             CMD=backup;    cmd_backup;    break ;;
            "forget+prune")       CMD=forget;    cmd_forget;    break ;;
            "copy to NAS")        CMD=copy;      cmd_copy;      break ;;
            "snapshots (local)")  REMOTE=0; cmd_snapshots;      break ;;
            "snapshots (remote)") REMOTE=1; cmd_snapshots;      break ;;
            "check (local)")      REMOTE=0; cmd_check;          break ;;
            "check (remote)")     REMOTE=1; cmd_check;          break ;;
            "stats (local)")      REMOTE=0; cmd_stats;          break ;;
            "stats (remote)")     REMOTE=1; cmd_stats;          break ;;
            "unlock (local)")     REMOTE=0; cmd_unlock;         break ;;
            "unlock (remote)")    REMOTE=1; cmd_unlock;         break ;;
            "pause containers")   pause_containers; trap - EXIT; break ;;
            "unpause containers") docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"; break ;;
            "full dry-run")       cmd_dry_run;   break ;;
            "quit")               break ;;
            *) echo "invalid selection" ;;
        esac
    done
}

parse_args "$@"

case "${CMD:-menu}" in
    backup)    cmd_backup ;;
    forget)    cmd_forget ;;
    copy)      cmd_copy ;;
    snapshots) cmd_snapshots ;;
    check)     cmd_check ;;
    stats)     cmd_stats ;;
    unlock)    cmd_unlock ;;
    pause)     pause_containers; trap - EXIT ;;
    unpause)   docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}" ;;
    dry-run)   cmd_dry_run ;;
    menu)      cmd_menu ;;
    *) echo "ERROR: unknown command: $CMD" >&2; usage; exit 2 ;;
esac
