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
# Reports the outcome to an Uptime Kuma push monitor (optional - see
# "Failure notifications" in backup/README.md).
#
# Shared paths, container set, and restic invocations live in backup/lib.sh
# so this file and backup-cli.sh stay in lockstep.
#
# Prerequisites:
#   1. restic installed on the host
#   2. /etc/restic/fox-cafe.env created (see backup/README.md)
#   3. Repo initialised: . /etc/restic/fox-cafe.env && restic -r "$LOCAL_REPOSITORY" init
#   4. NFS mount configured in /etc/fstab (see backup/README.md)
#   5. systemd timer enabled: systemctl enable --now backup-fox-cafe.timer

# -E so the ERR trap below is inherited into lib.sh's functions.
set -eEuo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
fc_load_env

# Heartbeat to the Uptime Kuma push monitor. KUMA_PUSH_URL carries a secret
# token so it lives in the env file, not this repo; unset disables the push.
# Never fatal: a monitoring blip must not fail an otherwise good backup.
# SECONDS is script-start elapsed, reported as the monitor's ping so Kuma
# graphs how long the backup takes.
fc_push() {
    [[ -n "${KUMA_PUSH_URL:-}" ]] || return 0
    curl -fsS --max-time 10 -o /dev/null -G "$KUMA_PUSH_URL" \
        --data-urlencode "status=$1" \
        --data-urlencode "msg=$2" \
        --data-urlencode "ping=$((SECONDS * 1000))" \
        || echo "WARNING: Kuma push ($1) failed" >&2
}

trap 'fc_push down "line $LINENO: $BASH_COMMAND"' ERR

fc_pause

fc_backup --tag nightly

# Source data is captured - bring containers back up before the slower
# repo-maintenance steps (forget/prune/copy) which only touch restic repos.
fc_unpause

# Degraded-but-not-failed steps. Collected here and appended to the success
# heartbeat so a persistently broken offsite copy is visible in Kuma instead
# of hiding behind a green tick.
warnings=()

# Forget+prune is best-effort: a flaky prune shouldn't skip the offsite copy
# below. Without this, set -e would abort the script and we'd lose a night
# of remote sync over a transient prune failure (e.g. a stale lock).
rc=0
fc_forget || rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "WARNING: restic forget/prune failed (rc=$rc) - continuing to remote copy"
    warnings+=("[forget/prune rc=$rc]")
fi

# Best-effort offsite copy. mount-missing (rc=2) is a warning, not a failure.
rc=0
fc_copy || rc=$?
case "$rc" in
    0) ;;
    2) echo "WARNING: $REMOTE_MOUNT not mounted - skipping remote copy"
       warnings+=("[offsite skipped: not mounted]") ;;
    *) echo "WARNING: remote restic copy failed (rc=$rc) - local backup still intact"
       warnings+=("[offsite rc=$rc]") ;;
esac

if (( ${#warnings[@]} )); then
    fc_push up "OK, degraded: ${warnings[*]}"
else
    fc_push up "OK"
fi
