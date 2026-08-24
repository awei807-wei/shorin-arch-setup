#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TRANSACTION_SCRIPT=$ROOT_DIR/scripts/modules/desktop-niri/transaction.sh
TEST_DIR=$(mktemp -d)

cleanup() {
    chmod -R u+rwX "$TEST_DIR" 2>/dev/null || true
    find -P "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

source "$TRANSACTION_SCRIPT"

[ "$(niri_desktop_txn_default_root)" = \
    /var/tmp/shorin-arch-setup/transactions ] ||
    fail 'desktop transactions must default to persistent storage outside TMPDIR'
grep -Fq 'cp -a --reflink=auto --' "$TRANSACTION_SCRIPT" ||
    fail 'desktop transaction copies must request copy-on-write reflinks'

test_full_tmpdir_does_not_block_transaction() (
    local tiny_tmp=$TEST_DIR/tiny-tmpfs
    local disk_parent=$TEST_DIR/persistent-state
    local disk_root=$disk_parent/transactions
    local stage argument

    mkdir -p "$tiny_tmp" "$disk_parent"
    chmod 0500 "$tiny_tmp"
    export TMPDIR=$tiny_tmp NIRI_DESKTOP_TXN_ROOT=$disk_root
    # Simulate a full 2 GiB tmpfs deterministically: any attempt to allocate
    # there fails, while the explicitly persistent transaction root works.
    mktemp() {
        for argument in "$@"; do :; done
        case "$argument" in
            "$TMPDIR"/*) return 1 ;;
        esac
        command mktemp "$@"
    }

    niri_desktop_txn_begin ||
        fail 'an exhausted TMPDIR must not block a persistent transaction'
    stage=$NIRI_DESKTOP_TXN_DIR
    case "$stage" in
        "$disk_root"/txn.*) ;;
        *) fail 'transaction stage escaped the configured persistent root' ;;
    esac
    [ "$(stat -c '%a' "$disk_root")" = 700 ] ||
        fail 'transaction root must use mode 0700'
    [ "$(stat -c '%u:%g' "$disk_root")" = "$(id -u):$(id -g)" ] ||
        fail 'transaction root must belong to the invoking identity'
    [ "$(stat -c '%a' "$stage")" = 700 ] ||
        fail 'transaction stage must use mode 0700'
    niri_desktop_txn_finish 0 || fail 'empty transaction commit failed'
    [ ! -e "$stage" ] || fail 'commit left its transaction stage behind'
)

test_nested_snapshot_rolls_back_once() (
    local disk_parent=$TEST_DIR/nested-state
    local target=$TEST_DIR/home/.local
    local baseline=$TEST_DIR/nested-baseline
    local external=$TEST_DIR/external-sentinel
    local stage status=0

    mkdir -p "$disk_parent" "$target/share/vicinae/extensions/screen-capture"
    export NIRI_DESKTOP_TXN_ROOT=$disk_parent/transactions
    printf 'original recorder\n' \
        > "$target/share/vicinae/extensions/screen-capture/record.js"
    printf 'large live tree\n' > "$target/share/cache.bin"
    printf 'external must survive\n' > "$external"
    ln -s "$external" "$target/share/external-link"
    chmod 0750 "$target/share"
    cp -a "$target" "$baseline"

    niri_desktop_txn_begin || fail 'nested rollback transaction did not start'
    stage=$NIRI_DESKTOP_TXN_DIR
    niri_desktop_txn_snapshot "$target" || fail 'ancestor snapshot failed'
    niri_desktop_txn_snapshot "$target/share" ||
        fail 'an ancestor-covered directory must be accepted'
    niri_desktop_txn_snapshot \
        "$target/share/vicinae/extensions/screen-capture/record.js" ||
        fail 'an ancestor-covered file must be accepted'
    [ "${#NIRI_DESKTOP_TXN_PATHS[@]}" -eq 1 ] ||
        fail 'nested targets created redundant recursive backups'
    [ "$(find "$stage" -mindepth 1 -maxdepth 1 -name 'entry-*' | wc -l)" \
        -eq 1 ] || fail 'nested transaction stored more than one backup root'

    printf 'mutated recorder\n' \
        > "$target/share/vicinae/extensions/screen-capture/record.js"
    rm -f "$target/share/external-link" "$target/share/cache.bin"
    printf 'new file\n' > "$target/share/new-file"
    chmod 0777 "$target/share"
    niri_desktop_txn_finish 1 || status=$?
    [ "$status" -eq 1 ] || fail 'rollback must preserve the triggering failure'
    diff -qr --no-dereference "$baseline" "$target" >/dev/null ||
        fail 'rollback did not restore the exact nested tree'
    [ "$(stat -c '%a' "$target/share")" = 750 ] ||
        fail 'rollback did not restore directory metadata'
    [ "$(readlink "$target/share/external-link")" = "$external" ] ||
        fail 'rollback did not restore the original symlink object'
    grep -Fqx 'external must survive' "$external" ||
        fail 'rollback followed and modified an external symlink target'
    [ ! -e "$stage" ] || fail 'rollback left its transaction stage behind'
)

test_absent_target_rollback_and_commit() (
    local disk_parent=$TEST_DIR/commit-state
    local absent=$TEST_DIR/home/.config/new-tree
    local committed=$TEST_DIR/home/.config/committed
    local rollback_stage commit_stage status=0

    mkdir -p "$disk_parent" "$(dirname "$absent")"
    export NIRI_DESKTOP_TXN_ROOT=$disk_parent/transactions

    niri_desktop_txn_begin || fail 'absent-target transaction did not start'
    rollback_stage=$NIRI_DESKTOP_TXN_DIR
    niri_desktop_txn_snapshot "$absent" || fail 'absent snapshot failed'
    mkdir -p "$absent/child"
    printf 'temporary\n' > "$absent/child/file"
    niri_desktop_txn_finish 1 || status=$?
    [ "$status" -eq 1 ] || fail 'absent-target rollback lost failure status'
    [ ! -e "$absent" ] || fail 'rollback left a newly created tree behind'
    [ ! -e "$rollback_stage" ] || fail 'absent rollback left staging data'

    mkdir -p "$committed"
    printf 'before\n' > "$committed/value"
    niri_desktop_txn_begin || fail 'commit transaction did not start'
    commit_stage=$NIRI_DESKTOP_TXN_DIR
    niri_desktop_txn_snapshot "$committed" || fail 'commit snapshot failed'
    printf 'after\n' > "$committed/value"
    niri_desktop_txn_finish 0 || fail 'transaction commit failed'
    grep -Fqx after "$committed/value" ||
        fail 'commit rolled back an intended mutation'
    [ ! -e "$commit_stage" ] || fail 'commit left staging data behind'
)

test_reverse_nesting_and_symlink_paths_fail_closed() (
    local disk_parent=$TEST_DIR/safety-state
    local target=$TEST_DIR/safety-target
    local linked_parent=$TEST_DIR/linked-parent
    local status=0

    mkdir -p "$disk_parent" "$target/child" "$linked_parent/real"
    export NIRI_DESKTOP_TXN_ROOT=$disk_parent/transactions
    printf 'original\n' > "$target/child/file"

    niri_desktop_txn_begin || fail 'safety transaction did not start'
    niri_desktop_txn_snapshot "$target/child" || fail 'child snapshot failed'
    if niri_desktop_txn_snapshot "$target" 2>/dev/null; then
        fail 'an ancestor registered after its child was accepted'
    fi
    [ "${#NIRI_DESKTOP_TXN_PATHS[@]}" -eq 1 ] ||
        fail 'rejected reverse nesting changed the snapshot set'
    if niri_desktop_txn_snapshot "$NIRI_DESKTOP_TXN_ROOT" 2>/dev/null; then
        fail 'a transaction accepted its own backup root as a target'
    fi
    niri_desktop_txn_finish 1 || status=$?
    [ "$status" -eq 1 ] || fail 'safety rollback lost failure status'

    ln -s "$linked_parent/real" "$linked_parent/link"
    niri_desktop_txn_begin || fail 'symlink safety transaction did not start'
    if niri_desktop_txn_snapshot "$linked_parent/link/file" 2>/dev/null; then
        fail 'a transaction target below a symlink was accepted'
    fi
    niri_desktop_txn_finish 0 || fail 'symlink safety cleanup failed'
)

test_unsafe_transaction_roots_are_preserved() (
    local parent=$TEST_DIR/unsafe-root-parent
    local wrong_mode=$parent/wrong-mode
    local real_root=$parent/real-root
    local linked_root=$parent/linked-root

    mkdir -p "$parent" "$wrong_mode" "$real_root"
    chmod 0755 "$wrong_mode"
    chmod 0700 "$real_root"
    if NIRI_DESKTOP_TXN_ROOT=$wrong_mode niri_desktop_txn_begin 2>/dev/null; then
        fail 'a transaction root with mode 0755 was accepted'
    fi
    [ "$(stat -c '%a' "$wrong_mode")" = 755 ] ||
        fail 'a rejected transaction root was silently rewritten'
    ln -s "$real_root" "$linked_root"
    if NIRI_DESKTOP_TXN_ROOT=$linked_root niri_desktop_txn_begin 2>/dev/null; then
        fail 'a symlinked transaction root was accepted'
    fi
    [ -L "$linked_root" ] || fail 'a rejected root symlink was removed'
)

test_full_tmpdir_does_not_block_transaction
test_nested_snapshot_rolls_back_once
test_absent_target_rollback_and_commit
test_reverse_nesting_and_symlink_paths_fail_closed
test_unsafe_transaction_roots_are_preserved

printf 'PASS: Niri desktop persistent transaction contract\n'
