#!/bin/bash
# Manual restic operations for fox_cafe.
#
# Wraps the same env, repos, and container set as backup.sh (via lib.sh) so
# ad-hoc work doesn't drift from the nightly job.
#
# Usage:
#   sudo backup/backup-cli.sh <command> [--dry-run] [--remote]
#   sudo backup/backup-cli.sh delete <snapshot-id> [--dry-run] [--remote]
#   sudo backup/backup-cli.sh menu              # interactive picker
#
# Commands:
#   backup              Pause containers, run restic backup, unpause
#   forget              Apply retention policy + prune (local repo)
#   copy                Copy local repo to remote
#   delete <id>         Forget + prune a specific snapshot by ID. Use this for
#                       manual snapshots (which the nightly forget never touches)
#                       or to remove a one-off mistake. Default: local repo.
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

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
fc_load_env

DRY_RUN=0
REMOTE=0
CMD=""
SNAPSHOT_ID=""

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --remote)  REMOTE=1 ;;
            -h|--help) usage; exit 0 ;;
            *)
                if [[ -z "$CMD" ]]; then
                    CMD="$1"
                elif [[ "$CMD" == "delete" && -z "$SNAPSHOT_ID" ]]; then
                    SNAPSHOT_ID="$1"
                else
                    echo "ERROR: unexpected argument: $1" >&2
                    exit 2
                fi
                ;;
        esac
        shift
    done
}

target_repo() {
    [[ "$REMOTE" -eq 1 ]] && echo "$REMOTE_REPOSITORY" || echo "$LOCAL_REPOSITORY"
}

dry_args() {
    [[ "$DRY_RUN" -eq 1 ]] && echo "--dry-run" || true
}

cmd_backup() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] skipping container pause/unpause"
        fc_backup --dry-run --tag manual
    else
        fc_pause
        fc_backup --tag manual
        fc_unpause
    fi
}

cmd_forget() { fc_forget $(dry_args); }

cmd_copy() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        # restic copy has no --dry-run flag, so show the snapshot diff instead:
        # snapshots present locally but missing on the remote are what a real
        # `copy` run would ship.
        # restic copy has no --dry-run flag of its own, so we approximate it
        # by diffing snapshot IDs: anything in the local repo with an ID not
        # present on the remote is what a real `copy` run would ship.
        echo "[dry-run] restic copy has no --dry-run; showing snapshots that would be copied:"
        if ! mountpoint -q "$REMOTE_MOUNT"; then
            echo "ERROR: $REMOTE_MOUNT not mounted" >&2
            return 1
        fi
        local local_ids remote_ids missing
        local_ids=$(restic -r "$LOCAL_REPOSITORY"  snapshots --json | jq -r '.[].id' | sort)
        remote_ids=$(restic -r "$REMOTE_REPOSITORY" snapshots --json | jq -r '.[].id' | sort)
        missing=$(comm -23 <(echo "$local_ids") <(echo "$remote_ids"))
        if [[ -z "$missing" ]]; then
            echo "(remote already has every local snapshot - nothing to copy)"
        else
            echo "$missing" | while read -r id; do
                [[ -n "$id" ]] && restic -r "$LOCAL_REPOSITORY" snapshots "$id"
            done
        fi
        return 0
    fi
    local rc=0
    fc_copy || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        echo "ERROR: $REMOTE_MOUNT not mounted" >&2
        return 1
    fi
    return "$rc"
}

# Delete a specific snapshot by ID. `restic forget <id> --prune` removes the
# snapshot reference and immediately reclaims its unique data. --prune honours
# --dry-run, so dry runs are non-destructive end to end.
cmd_delete() {
    if [[ -z "$SNAPSHOT_ID" ]]; then
        echo "ERROR: delete requires a snapshot ID (see 'snapshots' to find one)" >&2
        return 2
    fi
    "${RESTIC_NICE[@]}" restic -r "$(target_repo)" forget --prune $(dry_args) "$SNAPSHOT_ID"
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
        "delete snapshot (local)"
        "delete snapshot (remote)"
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
            "backup")             cmd_backup;    break ;;
            "forget+prune")       cmd_forget;    break ;;
            "copy to remote")        cmd_copy;      break ;;
            "delete snapshot (local)")  REMOTE=0; read -rp "snapshot ID: " SNAPSHOT_ID; cmd_delete; break ;;
            "delete snapshot (remote)") REMOTE=1; read -rp "snapshot ID: " SNAPSHOT_ID; cmd_delete; break ;;
            "snapshots (local)")  REMOTE=0; cmd_snapshots; break ;;
            "snapshots (remote)") REMOTE=1; cmd_snapshots; break ;;
            "check (local)")      REMOTE=0; cmd_check;     break ;;
            "check (remote)")     REMOTE=1; cmd_check;     break ;;
            "stats (local)")      REMOTE=0; cmd_stats;     break ;;
            "stats (remote)")     REMOTE=1; cmd_stats;     break ;;
            "unlock (local)")     REMOTE=0; cmd_unlock;    break ;;
            "unlock (remote)")    REMOTE=1; cmd_unlock;    break ;;
            "pause containers")   fc_pause; trap - EXIT;   break ;;
            "unpause containers") fc_unpause;              break ;;
            "full dry-run")       cmd_dry_run; break ;;
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
    delete)    cmd_delete ;;
    snapshots) cmd_snapshots ;;
    check)     cmd_check ;;
    stats)     cmd_stats ;;
    unlock)    cmd_unlock ;;
    pause)     fc_pause; trap - EXIT ;;
    unpause)   fc_unpause ;;
    dry-run)   cmd_dry_run ;;
    menu)      cmd_menu ;;
    *) echo "ERROR: unknown command: $CMD" >&2; usage; exit 2 ;;
esac
