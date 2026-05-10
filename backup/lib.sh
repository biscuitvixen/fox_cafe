#!/bin/bash
# Shared helpers for fox_cafe restic backups.
#
# Sourced by:
#   backup.sh       - nightly systemd job (env comes from EnvironmentFile)
#   backup-cli.sh   - interactive ops tool (env sourced from $ENV_FILE here)
#
# Defines: paths, container set, RESTIC_NICE, and the restic invocations
# (fc_backup / fc_forget / fc_copy) so the two entrypoints can't drift.

ENV_FILE="${ENV_FILE:-/etc/restic/fox-cafe.env}"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source env file if RESTIC_PASSWORD wasn't already provided. systemd sets it
# via EnvironmentFile for the nightly job; the CLI invocation needs to load it
# here. RESTIC_PASSWORD, LOCAL_REPOSITORY, REMOTE_MOUNT, and REMOTE_REPOSITORY
# all come from that file. Restic itself reads RESTIC_REPOSITORY, so we mirror
# LOCAL_REPOSITORY into it for the bare `restic backup` / `restic forget` calls
# below; the remote repo is passed explicitly via -r at copy time.
fc_load_env() {
    if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        if [[ ! -r "$ENV_FILE" ]]; then
            echo "ERROR: cannot read $ENV_FILE (run with sudo?)" >&2
            return 1
        fi
        # shellcheck disable=SC1090
        . "$ENV_FILE"
    fi
    export RESTIC_PASSWORD LOCAL_REPOSITORY REMOTE_MOUNT REMOTE_REPOSITORY
    export RESTIC_REPOSITORY="$LOCAL_REPOSITORY"
}

# Containers to pause during backup. Caddy and monitoring stay up.
# Filebrowser is included so its sqlite db is snapshotted with no writer attached.
# pause/unpause (SIGSTOP/SIGCONT) is used instead of stop/start so Docker
# doesn't treat the exit as a crash and auto-restart containers mid-backup.
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

# Run restic under nice + ionice so its disk I/O doesn't starve containers
# on the single shared sda1 volume.
#   nice -n10        : lower CPU priority (default 0, range -20..19)
#   ionice -c2 -n7   : best-effort I/O class, lowest priority within it
RESTIC_NICE=(nice -n10 ionice -c2 -n7)

# Pause containers and install a safety-net trap: unpause on exit even if the
# caller dies mid-backup. Caller must clear the trap (via fc_unpause) once it's
# done so the unpause doesn't fire a second time.
fc_pause() {
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" pause "${CONTAINERS[@]}"
    trap 'docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"' EXIT
}

fc_unpause() {
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" unpause "${CONTAINERS[@]}"
    trap - EXIT
}

# fc_backup [extra restic args...]
# Runs restic backup against BACKUP_PATHS with the standard excludes/tag.
# Caller is responsible for pause/unpause ordering.
fc_backup() {
    "${RESTIC_NICE[@]}" restic backup \
        "${BACKUP_PATHS[@]}" \
        --exclude "*/container_cache" \
        --exclude "*/Logs" \
        --tag fox-cafe \
        "$@"
}

# fc_forget [extra restic args...]
# Applies the retention policy + prune against the local repo.
fc_forget() {
    "${RESTIC_NICE[@]}" restic forget \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 3 \
        --keep-yearly 1 \
        --prune \
        --tag fox-cafe \
        "$@"
}

# fc_copy [extra restic args...]
# Mirror local repo to the remote NFS-mounted repo via restic copy. Both
# repos share chunker params (set at remote repo init via
# --copy-chunker-params) so dedup carries across; only new pack files are
# sent each run. RESTIC_FROM_PASSWORD covers the source (--from-repo) - the
# destination uses the regular RESTIC_PASSWORD.
# Returns 2 if the remote mount is missing so callers can decide whether
# that's fatal (CLI) or a warning (nightly best-effort).
fc_copy() {
    if ! mountpoint -q "$REMOTE_MOUNT"; then
        return 2
    fi
    RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
        "${RESTIC_NICE[@]}" restic -r "$REMOTE_REPOSITORY" copy \
            --from-repo "$LOCAL_REPOSITORY" \
            "$@"
}
