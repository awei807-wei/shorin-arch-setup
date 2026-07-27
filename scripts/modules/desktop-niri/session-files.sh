#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_fish_guard_contract() {
    cat <<'EOF'
if not contains "$HOME/.cargo/bin" $PATH
    set -gx PATH "$HOME/.cargo/bin" $PATH
end

if not contains "$HOME/.local/bin" $PATH
    set -gx PATH "$HOME/.local/bin" $PATH
end
EOF
}

niri_normalize_fish_contract() {
    awk '{
        sub(/\r$/, "")
        if ($0 !~ /^[[:space:]]*$/) print
    }'
}

niri_legacy_fish_file_is_managed() {
    local file=$1 renderer=$2 legacy_line=$3 guarded_line=$4 actual expected

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    actual=$(niri_normalize_fish_contract < "$file")
    expected=$("$renderer" | niri_normalize_fish_contract)
    [ "$actual" = "$expected" ] || [ "$actual" = "$legacy_line" ] ||
        [ "$actual" = "$guarded_line" ]
}

niri_fish_rustup_contract() {
    sed -n '1,3p' < <(niri_fish_guard_contract)
}

niri_fish_local_env_contract() {
    sed -n '5,7p' < <(niri_fish_guard_contract)
}

niri_fish_sources_satisfied() {
    niri_managed_text_matches "$NIRI_FISH_GUARD_FILE" \
        niri_fish_guard_contract &&
        ! niri_legacy_fish_file_is_managed "$NIRI_FISH_RUSTUP_FILE" \
            niri_fish_rustup_contract 'source "$HOME/.cargo/env.fish"' \
            'test -f "$HOME/.cargo/env.fish"; and source "$HOME/.cargo/env.fish"' &&
        ! niri_legacy_fish_file_is_managed "$NIRI_FISH_LOCAL_ENV_FILE" \
            niri_fish_local_env_contract 'source "$HOME/.local/bin/env.fish"' \
            'test -f "$HOME/.local/bin/env.fish"; and source "$HOME/.local/bin/env.fish"'
}

niri_bash_profile_contract() {
    # -l tells niri-session it is already inside a login shell. Without it,
    # niri-session re-execs "$SHELL" as a login shell to import the login
    # environment; when that shell is bash it reads .bash_profile again and
    # loops instead of starting the session.
    cat <<'EOF'
# >>> shorin niri tty1 >>>
if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then
    exec niri-session -l
fi
# <<< shorin niri tty1 <<<
EOF
}

niri_bash_profile_satisfied() {
    local actual expected begin_count end_count

    [ -f "$NIRI_BASH_PROFILE" ] || return 1
    ! grep -Fq '# shorin:niri-session:start' "$NIRI_BASH_PROFILE" || return 1
    ! grep -Fq '# shorin:niri-session:end' "$NIRI_BASH_PROFILE" || return 1
    begin_count=$(grep -Fxc '# >>> shorin niri tty1 >>>' "$NIRI_BASH_PROFILE" || true)
    end_count=$(grep -Fxc '# <<< shorin niri tty1 <<<' "$NIRI_BASH_PROFILE" || true)
    [ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ] || return 1
    actual=$(awk '
        $0 == "# >>> shorin niri tty1 >>>" { capture=1 }
        capture { print }
        $0 == "# <<< shorin niri tty1 <<<" { capture=0 }
    ' "$NIRI_BASH_PROFILE")
    expected=$(niri_bash_profile_contract)
    [ "$actual" = "$expected" ]
}

niri_legacy_autostart_absent() {
    [ ! -e "$NIRI_LEGACY_UNIT" ] && [ ! -L "$NIRI_LEGACY_UNIT" ] &&
        [ ! -e "$NIRI_LEGACY_UNIT_LINK" ] &&
        [ ! -L "$NIRI_LEGACY_UNIT_LINK" ]
}

niri_user_bus_is_available() {
    local uid

    uid=$(id -u "$1") || return 1
    [ -S "${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid/bus" ]
}

niri_reload_user_manager() {
    local user=$1 uid runtime_dir

    niri_user_bus_is_available "$user" || return 0
    uid=$(id -u "$user")
    runtime_dir="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user daemon-reload || return
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user reset-failed niri-autostart.service || true
}

niri_disable_legacy_user_unit() {
    local user=$1 uid runtime_dir active enabled

    niri_user_bus_is_available "$user" || return 0
    uid=$(id -u "$user")
    runtime_dir="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    if runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user is-active --quiet niri-autostart.service; then
        active=0
    else
        active=$?
        case "$active" in
            3|4) ;;
            *) return "$active" ;;
        esac
    fi
    if runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user is-enabled --quiet niri-autostart.service; then
        enabled=0
    else
        enabled=$?
        case "$enabled" in
            1|4) ;;
            *) return "$enabled" ;;
        esac
    fi
    [ "$active" -eq 0 ] || [ "$enabled" -eq 0 ] || return 0
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user disable --now niri-autostart.service
}

niri_install_rendered_file() {
    local destination=$1 renderer=$2 user=$3 temporary

    temporary=$(mktemp)
    "$renderer" > "$temporary"
    install_if_changed "$temporary" "$destination" 644
    rm -f "$temporary"
    chown "$user:" "$destination"
}

ensure_niri_fish_sources() {
    local user=$1

    install -d -o "$user" -g "$(id -gn "$user")" \
        "$(dirname "$NIRI_FISH_GUARD_FILE")"
    niri_install_rendered_file "$NIRI_FISH_GUARD_FILE" \
        niri_fish_guard_contract "$user"
    if niri_legacy_fish_file_is_managed "$NIRI_FISH_RUSTUP_FILE" \
        niri_fish_rustup_contract 'source "$HOME/.cargo/env.fish"' \
        'test -f "$HOME/.cargo/env.fish"; and source "$HOME/.cargo/env.fish"'; then
        rm -f "$NIRI_FISH_RUSTUP_FILE"
    fi
    if niri_legacy_fish_file_is_managed "$NIRI_FISH_LOCAL_ENV_FILE" \
        niri_fish_local_env_contract 'source "$HOME/.local/bin/env.fish"' \
        'test -f "$HOME/.local/bin/env.fish"; and source "$HOME/.local/bin/env.fish"'; then
        rm -f "$NIRI_FISH_LOCAL_ENV_FILE"
    fi
    niri_fish_sources_satisfied
}

ensure_niri_bash_profile() {
    local user=$1 temporary filtered mode=644 begin_count end_count
    local legacy_begin_count legacy_end_count

    niri_bash_profile_satisfied && niri_legacy_autostart_absent && return 0
    begin_count=$(grep -Fxc '# >>> shorin niri tty1 >>>' "$NIRI_BASH_PROFILE" 2>/dev/null || true)
    end_count=$(grep -Fxc '# <<< shorin niri tty1 <<<' "$NIRI_BASH_PROFILE" 2>/dev/null || true)
    legacy_begin_count=$(grep -Fxc '# shorin:niri-session:start' "$NIRI_BASH_PROFILE" 2>/dev/null || true)
    legacy_end_count=$(grep -Fxc '# shorin:niri-session:end' "$NIRI_BASH_PROFILE" 2>/dev/null || true)
    [ "$begin_count" -eq "$end_count" ] || return 2
    [ "$legacy_begin_count" -eq "$legacy_end_count" ] || return 2
    temporary=$(mktemp)
    filtered=$(mktemp)
    if [ -f "$NIRI_BASH_PROFILE" ]; then
        mode=$(stat -c '%a' "$NIRI_BASH_PROFILE")
        awk '
            $0 == "# >>> shorin niri tty1 >>>" ||
            $0 == "# shorin:niri-session:start" { skip=1; next }
            $0 == "# <<< shorin niri tty1 <<<" ||
            $0 == "# shorin:niri-session:end" { skip=0; next }
            !skip { print }
        ' "$NIRI_BASH_PROFILE" > "$filtered"
        awk '{ lines[NR]=$0 } END {
            last=NR
            while (last > 0 && lines[last] == "") last--
            for (i=1; i<=last; i++) print lines[i]
        }' "$filtered" > "$temporary"
    fi
    [ ! -s "$temporary" ] || printf '\n' >> "$temporary"
    niri_bash_profile_contract >> "$temporary"
    install_if_changed "$temporary" "$NIRI_BASH_PROFILE" "$mode"
    rm -f "$temporary" "$filtered"
    chown "$user:" "$NIRI_BASH_PROFILE"
    niri_disable_legacy_user_unit "$user" || return
    rm -f "$NIRI_LEGACY_UNIT_LINK" "$NIRI_LEGACY_UNIT"
    niri_reload_user_manager "$user"
    niri_bash_profile_satisfied && niri_legacy_autostart_absent
}
