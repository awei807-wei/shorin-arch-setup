#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256_DEFAULT=ed5888fb78a9d70d8085b2d16039ce7921b8e07171b9dc656d7dcdc0775c02fe

niri_fedora_recorder_source_path() {
    printf '%s\n' "${NIRI_FEDORA_RECORDER_SOURCE:-$SHORIN_ROOT/scripts/modules/desktop-niri/assets/shorin-fedora-recorder}"
}

niri_fedora_recorder_path() {
    printf '%s\n' "${NIRI_FEDORA_RECORDER_FILE:-$HOME_DIR/.local/bin/shorin-fedora-recorder}"
}

niri_fedora_vicinae_record_path() {
    printf '%s\n' "${NIRI_FEDORA_VICINAE_RECORD_FILE:-$HOME_DIR/.local/share/vicinae/extensions/screen-capture/record.js}"
}

niri_fedora_vicinae_record_bridge_contract() {
    cat <<'EOF'
const { execFile } = require("node:child_process");
const path = require("node:path");
const { showHUD, getPreferenceValues, showToast, Toast } = require("@vicinae/api");

module.exports = {
  default: async function Command() {
    const prefs = getPreferenceValues();
    const helper = path.join(process.env.HOME, ".local", "bin", "shorin-fedora-recorder");
    const result = await new Promise((resolve) => {
      execFile(helper, ["toggle", "--fps", String(prefs.fps || "15"), "--width", String(prefs.width || "640")], {
        encoding: "utf8",
        env: process.env,
        timeout: 600000,
        maxBuffer: 1024 * 1024,
      }, (error, stdout, stderr) => resolve({ error, stdout, stderr }));
    });
    const output = String(result.stdout || "").trim();
    const error = String(result.stderr || "").trim();
    if (result.error) {
      await showToast({ style: Toast.Style.Failure, title: "GIF recording failed", message: error || String(result.error.message) });
      return;
    }
    if (output === "cancelled") await showHUD("已取消");
    else if (output === "recording") await showHUD("🔴 录屏中... 再次调用停止");
    else if (output.startsWith("saved:")) await showHUD(`✓ GIF 就绪 → ${output.slice(6)}`);
    else await showHUD(output || "GIF recorder ready");
  },
};
EOF
}

niri_fedora_recorder_helper_satisfied() {
    local file source user=${1:-${TARGET_USER:-}}
    platform_is_fedora || return 0
    file=$(niri_fedora_recorder_path)
    source=$(niri_fedora_recorder_source_path)
    [ -f "$source" ] && [ ! -L "$source" ] || return 2
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    cmp -s "$source" "$file" || return 1
    [ "$(stat -c '%U' "$file" 2>/dev/null)" = "$user" ] || return 1
    [ "$(stat -c '%a' "$file" 2>/dev/null)" = 755 ]
}

niri_fedora_vicinae_record_bridge_content_matches() {
    local file
    platform_is_fedora || return 0
    file=$(niri_fedora_vicinae_record_path)
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    cmp -s <(niri_fedora_vicinae_record_bridge_contract) "$file"
}

niri_fedora_recorder_user_can_read() {
    local user=$1 file=$2

    if declare -F niri_run_as_user >/dev/null 2>&1; then
        niri_run_as_user "$user" test -r "$file"
    elif [ "$(id -u)" -eq "$(id -u "$user")" ]; then
        test -r "$file"
    else
        runuser -u "$user" -- test -r "$file"
    fi
}

niri_fedora_vicinae_record_bridge_satisfied() {
    local user=${1:-${TARGET_USER:-}} file
    platform_is_fedora || return 0
    [ -n "$user" ] || return 2
    file=$(niri_fedora_vicinae_record_path)
    niri_fedora_vicinae_record_bridge_content_matches || return 1
    [ "$(stat -c '%u' "$file" 2>/dev/null)" = "$(id -u "$user")" ] || return 1
    [ "$(stat -c '%a' "$file" 2>/dev/null)" = 644 ] || return 1
    niri_fedora_recorder_user_can_read "$user" "$file"
}

niri_fedora_vicinae_record_is_migratable() {
    local file actual expected
    file=$(niri_fedora_vicinae_record_path)
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    expected=${NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256:-$NIRI_FEDORA_VICINAE_RECORD_CANONICAL_SHA256_DEFAULT}
    actual=$(sha256sum "$file" | awk '{ print $1 }') || return 2
    [ "$actual" = "$expected" ]
}

niri_fedora_recorder_satisfied() {
    local user=${1:-${TARGET_USER:-}} bridge helper
    platform_is_fedora || return 0
    bridge=$(niri_fedora_vicinae_record_path)
    # The local extension is optional.  An absent, symlinked, or unknown
    # record.js is user-owned and therefore outside this desired state.
    [ -e "$bridge" ] || [ -L "$bridge" ] || return 0
    [ -f "$bridge" ] && [ ! -L "$bridge" ] || return 0
    if niri_fedora_vicinae_record_bridge_content_matches; then
        niri_fedora_vicinae_record_bridge_satisfied "$user" || return 1
        niri_fedora_recorder_helper_satisfied "$user"
        return
    fi
    niri_fedora_vicinae_record_is_migratable || return 0
    helper=$(niri_fedora_recorder_path)
    if [ -e "$helper" ] || [ -L "$helper" ]; then
        [ -f "$helper" ] && [ ! -L "$helper" ] &&
            cmp -s "$(niri_fedora_recorder_source_path)" "$helper" || return 0
    fi
    return 1
}

ensure_niri_fedora_recorder() {
    local user=$1 group helper source bridge helper_parent bridge_parent temporary
    require_writable_mode || return
    platform_is_fedora || return 0
    helper=$(niri_fedora_recorder_path)
    source=$(niri_fedora_recorder_source_path)
    bridge=$(niri_fedora_vicinae_record_path)
    # Preflight both destinations before making either change.  The extension
    # bridge is replaceable only at its audited canonical hash or when already
    # equal to the managed bridge.  Unknown files and symlinks are preserved.
    if [ ! -e "$bridge" ] && [ ! -L "$bridge" ]; then
        warn "Optional Vicinae screen-capture extension is absent; recorder bridge was not installed."
        return 0
    fi
    if [ -L "$bridge" ]; then
        warn "Preserving symlinked optional Vicinae record command: $bridge"
        return 0
    fi
    if [ ! -f "$bridge" ]; then
        warn "Preserving non-regular optional Vicinae record command: $bridge"
        return 0
    fi
    if ! niri_fedora_vicinae_record_bridge_content_matches &&
        ! niri_fedora_vicinae_record_is_migratable; then
        warn "Preserving unknown optional Vicinae record command: $bridge"
        return 0
    fi
    # The bundled helper is required only after the optional command has been
    # identified as either managed or the exact audited migration source.
    # Missing, unknown, and redirected user extensions remain successful
    # no-ops even if an installer copy is incomplete.
    [ -f "$source" ] && [ ! -L "$source" ] || {
        error "Fedora recorder source is missing or unsafe: $source"
        return 1
    }
    if [ -e "$helper" ] || [ -L "$helper" ]; then
        if [ -L "$helper" ] || [ ! -f "$helper" ] || ! cmp -s "$source" "$helper"; then
            if niri_fedora_vicinae_record_bridge_content_matches; then
                error "Managed Vicinae recorder bridge has a conflicting helper: $helper"
                return 2
            fi
            warn "Preserving conflicting optional Fedora recorder helper: $helper"
            return 0
        fi
    fi

    group=$(id -gn "$user") || return 1
    helper_parent=$(dirname "$helper")
    bridge_parent=$(dirname "$bridge")
    niri_path_is_safe_no_symlink "$helper_parent" || return 1
    niri_path_is_safe_no_symlink "$bridge_parent" || return 1
    install -d -o "$user" -g "$group" "$helper_parent" "$bridge_parent" || return 1

    if [ ! -e "$helper" ]; then
        install -m 755 -o "$user" -g "$group" "$source" "${helper}.new" || {
            rm -f "${helper}.new"
            return 1
        }
        mv -f "${helper}.new" "$helper" || { rm -f "${helper}.new"; return 1; }
    fi
    chmod 755 "$helper" && chown "$user:$group" "$helper" || return 1

    if ! niri_fedora_vicinae_record_bridge_content_matches; then
        temporary=$(mktemp "$bridge_parent/.record.js.XXXXXX") || return 1
        niri_fedora_vicinae_record_bridge_contract > "$temporary"
        chmod 644 "$temporary" && chown "$user:$group" "$temporary" || {
            rm -f "$temporary"
            return 1
        }
        mv -f "$temporary" "$bridge" || { rm -f "$temporary"; return 1; }
    fi
    chmod 644 "$bridge" && chown "$user:$group" "$bridge" || return 1
    niri_fedora_recorder_satisfied "$user"
}
