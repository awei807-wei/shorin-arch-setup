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

niri_fish_config_contract() {
    cat <<'EOF'
# >>> shorin fish init >>>
if status is-interactive
    if command -q starship
        starship init fish | source
    end
    if command -q zoxide
        zoxide init fish --cmd cd | source
    end
    if command -q thefuck
        set -l thefuck_alias (thefuck --alias 2>/dev/null)
        if test $status -eq 0; and test (count $thefuck_alias) -gt 0
            printf '%s\n' $thefuck_alias | source
        end
    end
end
# <<< shorin fish init <<<
EOF
}

niri_fish_config_marker_state() {
    local file=$1

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    awk '
        $0 == "# >>> shorin fish init >>>" {
            begin++
            if (open) invalid=1
            open=1
            next
        }
        $0 == "# <<< shorin fish init <<<" {
            end++
            if (!open) invalid=1
            open=0
            next
        }
        END {
            if (open || invalid || begin > 1 || end > 1 || begin != end) exit 1
            if (begin == 0) exit 2
            exit 0
        }
    ' "$file"
}

niri_fish_config_block() {
    awk '
        $0 == "# >>> shorin fish init >>>" { capture=1 }
        capture { print }
        $0 == "# <<< shorin fish init <<<" { capture=0 }
    '
}

niri_fish_strip_top_level_legacy_lines() {
    local file=$1 output=${2:-/dev/stdout}

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    awk -v output="$output" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function is_legacy(value) {
            return value == "starship init fish | source" ||
                value == "zoxide init fish --cmd cd | source" ||
                value == "thefuck --alias | source"
        }
        function update_depth(value,    command) {
            command=value
            sub(/[[:space:]].*$/, "", command)
            if (command == "if" || command == "begin" ||
                command == "switch" || command == "for" ||
                command == "while" || command == "function") {
                depth++
            } else if (command == "end" && depth > 0) {
                depth--
            }
        }
        {
            raw=$0
            line=$0
            sub(/\r$/, "", line)
            value=trim(line)
            if (depth == 0 && is_legacy(value)) {
                found++
                update_depth(value)
                next
            }
            print raw > output
            update_depth(value)
        }
        END {
            close(output)
            exit(found > 0 ? 0 : 1)
        }
    ' "$file"
}

niri_fish_top_level_legacy_lines_absent() {
    local file=$1 status=0

    niri_fish_strip_top_level_legacy_lines "$file" /dev/null || status=$?
    [ "$status" -eq 1 ]
}

niri_fish_config_satisfied() {
    local actual expected

    [ -f "$NIRI_FISH_CONFIG_FILE" ] &&
        [ ! -L "$NIRI_FISH_CONFIG_FILE" ] || return 1
    niri_fish_config_marker_state "$NIRI_FISH_CONFIG_FILE" || return 1
    niri_fish_top_level_legacy_lines_absent "$NIRI_FISH_CONFIG_FILE" ||
        return 1
    actual=$(niri_fish_config_block < "$NIRI_FISH_CONFIG_FILE")
    expected=$(niri_fish_config_contract)
    [ "$actual" = "$expected" ]
}

# Kept as a compatibility query for callers that used to perform a live Fish
# login.  Verification is intentionally static and has no user-shell side
# effects.
niri_fish_login_satisfied() {
    local file

    niri_fish_config_satisfied || return 1
    [ -d "$HOME_DIR/.config/fish" ] || return 0
    while IFS= read -r -d '' file; do
        [ -e "$file" ] || return 1
        if [ "$file" = "$NIRI_FISH_RUSTUP_FILE" ] &&
            grep -Fq 'source "$HOME/.cargo/env.fish"' "$file"; then
            return 1
        fi
        if [ "$file" = "$NIRI_FISH_LOCAL_ENV_FILE" ] &&
            grep -Eq 'source "$HOME/.local/bin/env.fish"' "$file"; then
            return 1
        fi
    done < <(find "$HOME_DIR/.config/fish" -type l -print0)
}

ensure_niri_fish_config() {
    local user=$1 temporary backup sanitized mode had_file=0 status=0 marker_state

    require_writable_mode || return
    install -d -o "$user" -g "$(id -gn "$user")" \
        "$(dirname "$NIRI_FISH_CONFIG_FILE")"
    if [ -e "$NIRI_FISH_CONFIG_FILE" ] || [ -L "$NIRI_FISH_CONFIG_FILE" ]; then
        [ -f "$NIRI_FISH_CONFIG_FILE" ] && [ ! -L "$NIRI_FISH_CONFIG_FILE" ] ||
            return 1
        had_file=1
        mode=$(stat -c '%a' "$NIRI_FISH_CONFIG_FILE")
        backup=$(mktemp)
        cp -a "$NIRI_FISH_CONFIG_FILE" "$backup"
    else
        mode=644
        backup=$(mktemp)
    fi
    if [ "$had_file" -eq 1 ]; then
        marker_state=0
        niri_fish_config_marker_state "$NIRI_FISH_CONFIG_FILE" || marker_state=$?
        case "$marker_state" in
            0|2) ;;
            *)
                rm -f "$backup"
                return 1
                ;;
        esac
    else
        marker_state=2
    fi
    temporary=$(mktemp)
    sanitized="${temporary}.sanitized"
    if [ "$had_file" -eq 1 ]; then
        sanitized=$(mktemp)
        if ! niri_fish_strip_top_level_legacy_lines \
            "$NIRI_FISH_CONFIG_FILE" "$sanitized"; then
            # A non-zero status means there were no top-level legacy lines;
            # the sanitized copy is still the exact source to continue with.
            :
        fi
    fi
    if [ "$marker_state" -eq 0 ]; then
        niri_fish_config_contract > "${temporary}.block"
        awk -v block_file="${temporary}.block" '
            BEGIN {
                while ((getline line < block_file) > 0) block[++block_count] = line
                close(block_file)
            }
            $0 == "# >>> shorin fish init >>>" {
                for (i = 1; i <= block_count; i++) print block[i]
                in_block=1
                next
            }
            $0 == "# <<< shorin fish init <<<" { in_block=0; next }
            !in_block { print }
        ' "$sanitized" > "$temporary"
        rm -f "${temporary}.block"
    elif [ "$had_file" -eq 1 ]; then
        cp -a "$sanitized" "$temporary"
        [ ! -s "$temporary" ] || printf '\n' >> "$temporary"
        niri_fish_config_contract >> "$temporary"
    else
        niri_fish_config_contract > "$temporary"
    fi
    if ! install_if_changed "$temporary" "$NIRI_FISH_CONFIG_FILE" "$mode"; then
        rm -f "$temporary" "$backup" "$sanitized"
        return 1
    fi
    rm -f "$temporary" "$sanitized"
    chown "$user:$(id -gn "$user")" "$NIRI_FISH_CONFIG_FILE"
    if ! niri_fish_config_satisfied; then
        if [ "$had_file" -eq 1 ]; then
            install_if_changed "$backup" "$NIRI_FISH_CONFIG_FILE" "$mode" || status=1
            chown "$user:$(id -gn "$user")" "$NIRI_FISH_CONFIG_FILE" || status=1
        else
            rm -f "$NIRI_FISH_CONFIG_FILE" || status=1
        fi
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    return "$status"
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

    if platform_is_fedora; then
        niri_fedora_bash_profile_managed_block_satisfied
        return $?
    fi
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

niri_session_entry_satisfied() {
    local file

    if platform_is_fedora; then
        niri_fedora_wayland_session_entry_satisfied
        return $?
    fi
    niri_bash_profile_satisfied || return 1
    file=$NIRI_BASH_PROFILE
    awk '
        {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)
            if (line ~ /(^|[[:space:]])(exec[[:space:]]+)?(\/[^[:space:]]*\/)?niri([[:space:]]|$)/) found=1
        }
        END { exit found + 0 }
    ' "$file"
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

    if platform_is_fedora; then
        niri_fedora_remove_bash_profile_managed_blocks "$user" || return
        niri_fedora_remove_legacy_autostart "$user" || return
        niri_fedora_bash_profile_managed_block_satisfied || return
        niri_legacy_autostart_absent
        return $?
    fi
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
