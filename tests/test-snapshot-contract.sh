#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/scripts/modules/storage/targets.sh"
source "$ROOT_DIR/scripts/lib/snapshots.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

SNAPPER_LIST_STATUS=0
snapper() {
    [[ " $* " == *" list "* ]] || return 1
    [ "$SNAPPER_LIST_STATUS" -eq 0 ] || return "$SNAPPER_LIST_STATUS"
    printf '1\t"Before Shorin Setup"\n'
    printf '4\t"Other marker"\n'
    printf '7\t"Before Shorin Setup [run:current]"\n'
}

[ "$(snapshot_latest_id root 'Before Shorin Setup')" = 1 ] ||
    fail 'exact snapshot lookup must not mix different runs'
[ "$(snapshot_latest_record root 'Before Shorin Setup')" = \
    $'7\tBefore Shorin Setup [run:current]' ] ||
    fail 'rollback must select the newest run-scoped snapshot record'
if snapshot_latest_id root 'Before Shorin'; then
    fail 'snapshot lookup must not accept a partial marker'
fi
SNAPPER_LIST_STATUS=2
status=0
snapshot_latest_id root 'Before Shorin Setup' >/dev/null || status=$?
[ "$status" -eq 2 ] || fail 'snapshot list failures must remain distinguishable'

SNAPPER_LIST_STATUS=0
snapper() {
    [[ " $* " == *" list "* ]] || return 1
    if [[ " $* " == *" -c home "* ]]; then
        printf '1\t"Before Shorin Setup [run:paired;home:1]"\n'
    else
        printf '1\t"Before Shorin Setup [run:paired;home:1]"\n'
        printf '9\t"Before Shorin Setup [run:orphan;home:1]"\n'
    fi
}
[ "$(snapshot_latest_paired_record root home 'Before Shorin Setup')" = \
    $'1\tBefore Shorin Setup [run:paired;home:1]' ] ||
    fail 'pair lookup must skip a newer orphan root snapshot'

findmnt() { printf 'btrfs\n'; }
btrfs() { [ "${BTRFS_HOME_IS_SUBVOLUME:-0}" -eq 1 ]; }
BTRFS_HOME_IS_SUBVOLUME=0
if storage_home_is_btrfs; then
    fail '/home on Btrfs is insufficient without a dedicated subvolume'
fi
BTRFS_HOME_IS_SUBVOLUME=1
storage_home_is_btrfs || fail 'a Btrfs /home subvolume must be accepted'

ROLLBACK="$ROOT_DIR/scripts/checks/niri-rollback.sh"
if grep -Eq 'pacman -Sc|\.cache/(yay|paru)' "$ROLLBACK"; then
    fail 'desktop rollback must not delete unrelated package caches'
fi
root_lookup=$(grep -n 'snapshot_latest_record root' "$ROLLBACK" | cut -d: -f1)
home_lookup=$(grep -n 'snapshot_latest_id home' "$ROLLBACK" | cut -d: -f1)
root_rollback=$(grep -n 'perform_rollback root' "$ROLLBACK" | cut -d: -f1)
[ "$root_lookup" -lt "$root_rollback" ] && [ "$home_lookup" -lt "$root_rollback" ] ||
    fail 'both snapshot IDs must be resolved before the first rollback'

grep -Fq 'checkpoint-apply.sh' "$ROOT_DIR/scripts/modules/desktop-niri.sh" ||
    fail 'desktop checkpoint must be created immediately before desktop apply'
if grep -Fq 'checkpoint-apply.sh' "$ROOT_DIR/scripts/modules/storage.sh"; then
    fail 'storage must not create a premature duplicate desktop checkpoint'
fi

printf 'PASS: snapshot and rollback contract\n'
