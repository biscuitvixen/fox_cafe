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
# Shared paths, container set, and restic invocations live in backup/lib.sh
# so this file and backup-cli.sh stay in lockstep.
#
# Prerequisites:
#   1. restic installed on the host
#   2. /etc/restic/fox-cafe.env created (see backup/README.md)
#   3. Repo initialised: . /etc/restic/fox-cafe.env && restic -r "$LOCAL_REPOSITORY" init
#   4. NFS mount configured in /etc/fstab (see backup/README.md)
#   5. systemd timer enabled: systemctl enable --now backup-fox-cafe.timer

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
fc_load_env

fc_pause

fc_backup --tag nightly

# Source data is captured - bring containers back up before the slower
# repo-maintenance steps (forget/prune/copy) which only touch restic repos.
fc_unpause

fc_forget

# Best-effort offsite copy. mount-missing (rc=2) is a warning, not a failure.
rc=0
fc_copy || rc=$?
case "$rc" in
    0) ;;
    2) echo "WARNING: $REMOTE_MOUNT not mounted - skipping remote copy" ;;
    *) echo "WARNING: remote restic copy failed (rc=$rc) - local backup still intact" ;;
esac
