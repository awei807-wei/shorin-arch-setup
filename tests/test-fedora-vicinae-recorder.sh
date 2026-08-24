#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER=$ROOT_DIR/scripts/modules/desktop-niri/assets/shorin-fedora-recorder
TEST_DIR=$(mktemp -d)
cleanup() {
    [ -e "$TEST_DIR" ] || [ -L "$TEST_DIR" ] || return 0
    find -P "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FAKE_BIN=$TEST_DIR/bin
HOME_DIR=$TEST_DIR/home
RUNTIME_DIR=$TEST_DIR/runtime
STATE_HOME=$TEST_DIR/state-home
OUTPUT_DIR=$TEST_DIR/output
mkdir -p "$FAKE_BIN" "$HOME_DIR" "$RUNTIME_DIR" "$STATE_HOME" "$OUTPUT_DIR"

cat > "$FAKE_BIN/slurp" <<'EOF'
#!/usr/bin/env bash
printf '10,20 320x240\n'
EOF
cat > "$FAKE_BIN/wf-recorder" <<'EOF'
#!/usr/bin/env bash
output=
codec=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -f|--file) output=$2; shift 2 ;;
        --codec|-c) codec=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$codec" >> "$FAKE_RECORDER_CODEC_LOG"
printf '%s\n' "$$" >> "$FAKE_RECORDER_PID_LOG"
[ "${FAKE_RECORDER_EXIT_EARLY:-0}" = 0 ] || exit 9
finish() { printf 'source-video\n' > "$output"; exit 0; }
trap finish INT TERM
while :; do sleep 0.05; done
EOF
cat > "$FAKE_BIN/ffmpeg" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' -encoders '*)
        printf 'Encoders:\n V..... libopenh264 fake\n V..... libvpx-vp9 fake\n'
        exit 0
        ;;
    *' -filters '*)
        printf 'Filters:\n ... palettegen V->V\n ... paletteuse VV->V\n'
        exit 0
        ;;
esac
printf '%s\n' "$*" >> "$FAKE_FFMPEG_LOG"
[ "${FAKE_FFMPEG_FAIL:-0}" = 0 ] || exit 7
for last; do :; done
printf 'GIF89a\n' > "$last"
EOF
cat > "$FAKE_BIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat > "$FAKE_CLIPBOARD_LOG"
EOF
chmod 755 "$FAKE_BIN"/*

export PATH="$FAKE_BIN:$PATH"
export HOME=$HOME_DIR XDG_RUNTIME_DIR=$RUNTIME_DIR XDG_STATE_HOME=$STATE_HOME
export SHORIN_RECORDER_OUTPUT_DIR=$OUTPUT_DIR
export SHORIN_RECORDER_START_DELAY=0.05 SHORIN_RECORDER_STOP_INTERVAL=0.02
export SHORIN_RECORDER_STOP_POLLS=10
export FAKE_RECORDER_CODEC_LOG=$TEST_DIR/codec.log
export FAKE_RECORDER_PID_LOG=$TEST_DIR/recorder-pid.log
export FAKE_FFMPEG_LOG=$TEST_DIR/ffmpeg.log
export FAKE_CLIPBOARD_LOG=$TEST_DIR/clipboard.log

# Status is a pure observation: it must not initialize runtime or log paths.
status_root=$TEST_DIR/status-only
status_output=$(XDG_RUNTIME_DIR="$status_root/runtime" \
    XDG_STATE_HOME="$status_root/state" bash "$HELPER" status)
[ "$status_output" = idle ] || fail 'status must report idle before capture'
[ ! -e "$status_root/runtime" ] && [ ! -e "$status_root/state" ] ||
    fail 'status must not create runtime or log directories'

unsafe_root=$TEST_DIR/unsafe-runtime
unsafe_target=$TEST_DIR/unsafe-target
mkdir -p "$unsafe_root" "$unsafe_target"
ln -s "$unsafe_target" "$unsafe_root/state-link"
if SHORIN_RECORDER_STATE_DIR=$unsafe_root/state-link bash "$HELPER" start >/dev/null 2>&1; then
    fail 'symlinked recorder state directory was accepted'
fi
[ -z "$(find "$unsafe_target" -mindepth 1 -print -quit)" ] ||
    fail 'symlinked recorder state directory was traversed'

lock_state=$TEST_DIR/unsafe-lock-state
lock_target=$TEST_DIR/unsafe-lock-target
mkdir -p "$lock_state"
printf 'unchanged\n' > "$lock_target"
ln -s "$lock_target" "$lock_state/lock"
if SHORIN_RECORDER_STATE_DIR=$lock_state bash "$HELPER" stop >/dev/null 2>&1; then
    fail 'symlinked recorder lock was accepted'
fi
[ "$(< "$lock_target")" = unchanged ] || fail 'symlinked lock target was modified'

open_state=$TEST_DIR/world-writable-state
mkdir -m 777 "$open_state"
if SHORIN_RECORDER_STATE_DIR=$open_state bash "$HELPER" stop >/dev/null 2>&1; then
    fail 'world-writable recorder state directory was accepted'
fi

new_state=$TEST_DIR/new-symlink-state
new_target=$TEST_DIR/new-symlink-target
mkdir -m 700 "$new_state"
printf 'unchanged-new\n' > "$new_target"
ln -s "$new_target" "$new_state/work-file.new"
SHORIN_RECORDER_STATE_DIR=$new_state bash "$HELPER" start >/dev/null ||
    fail 'safe removal of a state staging symlink prevented recording start'
[ "$(< "$new_target")" = unchanged-new ] ||
    fail 'state staging symlink target was modified'
SHORIN_RECORDER_STATE_DIR=$new_state bash "$HELPER" stop >/dev/null ||
    fail 'recording with a safely replaced state staging file did not stop'

# A state commit failure after wf-recorder starts must stop and reap the exact
# process, then remove its unpublished work and every partial regular state
# file.  An unexpected directory at a state filename remains preserved.
commit_state=$TEST_DIR/commit-failure-state
mkdir -m 700 "$commit_state"
mkdir "$commit_state/started.new"
: > "$FAKE_RECORDER_PID_LOG"
if SHORIN_RECORDER_STATE_DIR=$commit_state bash "$HELPER" start \
    >/dev/null 2>&1; then
    fail 'injected recorder state commit failure was reported as success'
fi
commit_pid=$(tail -n 1 "$FAKE_RECORDER_PID_LOG")
[[ "$commit_pid" =~ ^[1-9][0-9]*$ ]] ||
    fail 'state commit fault did not record the started recorder PID'
for _ in {1..50}; do
    kill -0 "$commit_pid" 2>/dev/null || break
    sleep 0.02
done
if kill -0 "$commit_pid" 2>/dev/null; then
    fail 'state commit failure left an orphan recorder process'
fi
for state_file in pid start-token work-file source-extension started; do
    [ ! -e "$commit_state/$state_file" ] &&
        [ ! -L "$commit_state/$state_file" ] ||
        fail "state commit failure left partial state: $state_file"
done
[ -d "$commit_state/started.new" ] ||
    fail 'state cleanup deleted an unexpected user directory recursively'
[ -z "$(find "$commit_state" -maxdepth 1 -type f \
    -name 'recording.*' -print -quit)" ] ||
    fail 'state commit failure left an unpublished recording work file'
[ "$(SHORIN_RECORDER_STATE_DIR=$commit_state bash "$HELPER" status)" = idle ] ||
    fail 'state commit failure did not return the helper to idle'

# Fedora codec selection must skip absent libx264, start without audio, confirm
# liveness, then atomically create the GIF and copy its URI.
[ "$(bash "$HELPER" start --fps 12 --width 800)" = recording ] ||
    fail 'GIF start did not report recording'
[ "$(bash "$HELPER" status)" = recording ] || fail 'live status was not reported'
[ "$(tail -n 1 "$FAKE_RECORDER_CODEC_LOG")" = libopenh264 ] ||
    fail 'Fedora helper did not select the available libopenh264 encoder'
[ "$(bash "$HELPER" stop --fps 12 --width 800)" != idle ] ||
    fail 'GIF stop unexpectedly reported idle'
gif=$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.gif' -print -quit)
[ -n "$gif" ] && [ -s "$gif" ] || fail 'GIF conversion did not create an output'
find "$OUTPUT_DIR" -maxdepth 1 -name '*.part' -print -quit | grep -q . &&
    fail 'successful conversion left a non-atomic .part file'
grep -Fq 'palettegen' "$FAKE_FFMPEG_LOG" && grep -Fq 'paletteuse' "$FAKE_FFMPEG_LOG" ||
    fail 'GIF conversion did not use palettegen and paletteuse'
[ "$(< "$FAKE_CLIPBOARD_LOG")" = "file://$gif" ] ||
    fail 'successful conversion did not copy the GIF URI'
[ "$(bash "$HELPER" status)" = idle ] || fail 'state was not cleared after success'

# Invalid Vicinae text preferences must be rejected before slurp/capture.
if bash "$HELPER" start --fps '15;touch /tmp/no' --width 640 >/dev/null 2>&1; then
    fail 'invalid fps preference was accepted'
fi
[ "$(bash "$HELPER" status)" = idle ] || fail 'invalid preferences created capture state'

# A recorder that exits immediately must not publish a PID or claim success.
if FAKE_RECORDER_EXIT_EARLY=1 bash "$HELPER" start >/dev/null 2>&1; then
    fail 'early wf-recorder exit was not detected'
fi
[ "$(bash "$HELPER" status)" = idle ] || fail 'failed start published live state'

# Conversion failure keeps a playable source, removes the GIF part, and clears
# runtime state so a later invocation can start again.
failure_output=$TEST_DIR/failure-output
mkdir -p "$failure_output"
SHORIN_RECORDER_OUTPUT_DIR=$failure_output bash "$HELPER" start >/dev/null
if SHORIN_RECORDER_OUTPUT_DIR=$failure_output FAKE_FFMPEG_FAIL=1 \
    bash "$HELPER" stop >/dev/null 2>&1; then
    fail 'ffmpeg conversion failure was reported as success'
fi
source_video=$(find "$failure_output" -maxdepth 1 -type f \
    -name 'failed-recording-*' -print -quit)
[ -n "$source_video" ] && [ -s "$source_video" ] ||
    fail 'conversion failure did not preserve the source video'
find "$failure_output" -maxdepth 1 -name '*.gif' -o -name '*.part' |
    grep -q . && fail 'conversion failure published a GIF or left a part file'
[ "$(bash "$HELPER" status)" = idle ] || fail 'conversion failure left active state'

# Dead-PID state is cleaned safely and its non-empty source is retained.
stale_state=$TEST_DIR/stale-state
stale_output=$TEST_DIR/stale-output
mkdir -p "$stale_state" "$stale_output"
printf '999999\n' > "$stale_state/pid"
printf '1\n' > "$stale_state/start-token"
printf '%s\n' "$stale_state/recording.stale.mp4" > "$stale_state/work-file"
printf 'mp4\n' > "$stale_state/source-extension"
printf 'stale-video\n' > "$stale_state/recording.stale.mp4"
SHORIN_RECORDER_STATE_DIR=$stale_state SHORIN_RECORDER_OUTPUT_DIR=$stale_output \
    bash "$HELPER" stop >/dev/null
[ ! -e "$stale_state/pid" ] || fail 'stale PID state was not removed'
find "$stale_output" -type f -name 'failed-recording-*' -print -quit |
    grep -q . || fail 'stale source was not preserved'

# Contract migration: only the audited hash may be replaced.  An absent plugin,
# unknown regular file, symlink, and unknown helper are optional no-ops.
TARGET_USER=$(id -un)
export TARGET_USER HOME_DIR SHORIN_ROOT=$ROOT_DIR SHORIN_MODE=repair
source "$ROOT_DIR/scripts/lib/files.sh"
platform_is_fedora() { return 0; }
error() { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
niri_path_is_safe_no_symlink() {
    local path=$1 part current=
    [[ "$path" = /* ]] || return 1
    IFS=/ read -ra parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        current="$current/$part"
        [ ! -L "$current" ] || return 1
    done
}
source "$ROOT_DIR/scripts/modules/desktop-niri/fedora-recorder-contract.sh"

absent_home=$TEST_DIR/absent-home
export HOME_DIR=$absent_home
NIRI_FEDORA_RECORDER_SOURCE=$TEST_DIR/missing-helper-source \
    ensure_niri_fedora_recorder "$TARGET_USER" ||
    fail 'absent optional extension must be a no-op before source validation'
[ ! -e "$absent_home/.local/bin/shorin-fedora-recorder" ] &&
    [ ! -e "$absent_home/.local/share/vicinae/extensions/screen-capture/record.js" ] ||
    fail 'absent optional extension caused files to be created'
niri_fedora_recorder_satisfied "$TARGET_USER" ||
    fail 'absent optional extension must satisfy the optional contract'

contract_home=$TEST_DIR/contract-home
record_file=$contract_home/.local/share/vicinae/extensions/screen-capture/record.js
helper_file=$contract_home/.local/bin/shorin-fedora-recorder
mkdir -p "$(dirname "$record_file")"
printf 'audited fixture\n' > "$record_file"
export HOME_DIR=$contract_home NIRI_FEDORA_VICINAE_RECORD_FILE=$record_file
export NIRI_FEDORA_RECORDER_FILE=$helper_file
export NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256
NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256=$(sha256sum "$record_file" | awk '{ print $1 }')
ensure_niri_fedora_recorder "$TARGET_USER" || fail 'audited record.js migration failed'
niri_fedora_recorder_satisfied "$TARGET_USER" || fail 'migrated recorder contract is not satisfied'
managed_hash=$(sha256sum "$record_file" | awk '{ print $1 }')
chmod 600 "$record_file"
if niri_fedora_recorder_satisfied "$TARGET_USER"; then
    fail 'managed recorder bridge metadata drift was accepted by verify'
fi
ensure_niri_fedora_recorder "$TARGET_USER" ||
    fail 'managed recorder bridge metadata drift was not repaired'
[ "$(stat -c '%u:%a' "$record_file")" = "$(id -u "$TARGET_USER"):644" ] ||
    fail 'managed recorder bridge owner/mode did not converge to target:0644'
test -r "$record_file" || fail 'managed recorder bridge is not target-user readable'
[ "$(sha256sum "$record_file" | awk '{ print $1 }')" = "$managed_hash" ] ||
    fail 'metadata repair rewrote managed recorder bridge content'
first_hash=$(sha256sum "$helper_file" "$record_file")
ensure_niri_fedora_recorder "$TARGET_USER" || fail 'idempotent recorder apply failed'
[ "$first_hash" = "$(sha256sum "$helper_file" "$record_file")" ] ||
    fail 'second recorder apply changed managed files'

unknown_home=$TEST_DIR/unknown-home
unknown_record=$unknown_home/.local/share/vicinae/extensions/screen-capture/record.js
unknown_helper=$unknown_home/.local/bin/shorin-fedora-recorder
mkdir -p "$(dirname "$unknown_record")"
printf 'user custom command\n' > "$unknown_record"
HOME_DIR=$unknown_home NIRI_FEDORA_VICINAE_RECORD_FILE=$unknown_record \
NIRI_FEDORA_RECORDER_FILE=$unknown_helper \
NIRI_FEDORA_RECORDER_SOURCE=$TEST_DIR/missing-helper-source \
NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256=not-the-user-file \
    ensure_niri_fedora_recorder "$TARGET_USER" >/dev/null 2>&1 ||
    fail 'unknown optional record.js must be a successful no-op'
[ "$(< "$unknown_record")" = 'user custom command' ] && [ ! -e "$unknown_helper" ] ||
    fail 'unknown record.js was modified or caused a partial helper install'
HOME_DIR=$unknown_home NIRI_FEDORA_VICINAE_RECORD_FILE=$unknown_record \
NIRI_FEDORA_RECORDER_FILE=$unknown_helper \
NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256=not-the-user-file \
    niri_fedora_recorder_satisfied "$TARGET_USER" ||
    fail 'unknown optional record.js must satisfy check/verify without mutation'

link_home=$TEST_DIR/link-home
link_record=$link_home/.local/share/vicinae/extensions/screen-capture/record.js
link_helper=$link_home/.local/bin/shorin-fedora-recorder
mkdir -p "$(dirname "$link_record")"
ln -s /tmp/user-record.js "$link_record"
HOME_DIR=$link_home NIRI_FEDORA_VICINAE_RECORD_FILE=$link_record \
NIRI_FEDORA_RECORDER_FILE=$link_helper \
    ensure_niri_fedora_recorder "$TARGET_USER" >/dev/null 2>&1 ||
    fail 'symlinked optional record.js must be a successful no-op'
[ -L "$link_record" ] && [ "$(readlink "$link_record")" = /tmp/user-record.js ] &&
    [ ! -e "$link_helper" ] || fail 'symlinked record.js was not preserved'
HOME_DIR=$link_home NIRI_FEDORA_VICINAE_RECORD_FILE=$link_record \
NIRI_FEDORA_RECORDER_FILE=$link_helper \
    niri_fedora_recorder_satisfied "$TARGET_USER" ||
    fail 'symlinked optional record.js must satisfy check/verify without mutation'

conflict_home=$TEST_DIR/conflict-home
conflict_record=$conflict_home/.local/share/vicinae/extensions/screen-capture/record.js
conflict_helper=$conflict_home/.local/bin/shorin-fedora-recorder
mkdir -p "$(dirname "$conflict_record")" "$(dirname "$conflict_helper")"
printf 'audited fixture two\n' > "$conflict_record"
printf 'user helper\n' > "$conflict_helper"
conflict_record_hash=$(sha256sum "$conflict_record" | awk '{ print $1 }')
HOME_DIR=$conflict_home NIRI_FEDORA_VICINAE_RECORD_FILE=$conflict_record \
NIRI_FEDORA_RECORDER_FILE=$conflict_helper \
NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256=$conflict_record_hash \
    ensure_niri_fedora_recorder "$TARGET_USER" >/dev/null 2>&1 ||
    fail 'unknown optional helper must be a successful no-op before migration'
[ "$(< "$conflict_helper")" = 'user helper' ] &&
    [ "$(< "$conflict_record")" = 'audited fixture two' ] ||
    fail 'unknown helper conflict modified user files'

grep -Fq "$NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256_DEFAULT" \
    "$ROOT_DIR/scripts/modules/desktop-niri/fedora-recorder-contract.sh" ||
    fail 'audited canonical record.js hash is not pinned'
grep -Fq 'fedora-recorder-contract.sh' \
    "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh" ||
    fail 'desktop targets do not source the Fedora recorder contract'
for distro in arch fedora; do
    empty_profile=$TEST_DIR/empty-$distro-profile
    empty_list=$TEST_DIR/empty-$distro-list
    : > "$empty_profile"
    : > "$empty_list"
    legacy_targets=$(SHORIN_DISTRO=$distro SHORIN_ROOT=$ROOT_DIR \
        EMPTY_PROFILE=$empty_profile EMPTY_LIST=$empty_list bash -c '
            source "$SHORIN_ROOT/scripts/modules/desktop-niri/targets.sh"
            niri_all_package_targets "$EMPTY_PROFILE" "$EMPTY_LIST"
        ')
    grep -Fqx wf-recorder <<< "$legacy_targets" ||
        fail "$distro legacy empty profile dropped required wf-recorder"
done
grep -Fq 'runtime:vicinae-gif-recorder' \
    "$ROOT_DIR/scripts/modules/desktop-niri.sh" ||
    fail 'desktop check/verify does not expose the Vicinae GIF recorder target'
grep -Fq 'ensure_niri_fedora_recorder "$TARGET_USER"' \
    "$ROOT_DIR/scripts/modules/desktop-niri/dotfiles-apply.sh" ||
    fail 'dotfiles apply does not converge the optional recorder bridge'
grep -Fq 'execFile(helper' \
    "$ROOT_DIR/scripts/modules/desktop-niri/fedora-recorder-contract.sh" ||
    fail 'Vicinae bridge must invoke the helper asynchronously'
if grep -Fq 'spawnSync' \
    "$ROOT_DIR/scripts/modules/desktop-niri/fedora-recorder-contract.sh"; then
    fail 'Vicinae bridge must not block the extension manager with spawnSync'
fi

printf 'PASS: Fedora Vicinae GIF recorder compatibility\n'
