#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Application-specific convergence. This file is sourced after target parsing.

wine_server_verify_stopped() {
    local wine_prefix=$1

    if as_user env HOME="$HOME_DIR" WINEPREFIX="$wine_prefix" \
        timeout 30s wineserver -w; then
        return 0
    fi
    error "The managed wineserver did not stop for prefix $wine_prefix."
    return 1
}

stop_wine_server() {
    local wine_prefix=$1 stop_status=0

    as_user env HOME="$HOME_DIR" WINEPREFIX="$wine_prefix" \
        timeout 30s wineserver -k || stop_status=$?
    # wineserver -k returns non-zero when there is nothing to stop on some
    # Wine builds.  Treat that exact no-process state as idempotent, while
    # preserving command/query failures and a server that remains alive.
    if [ "$stop_status" -gt 1 ]; then
        error "wineserver -k failed for $TARGET_USER (status $stop_status)."
        return "$stop_status"
    fi
    wine_server_verify_stopped "$wine_prefix"
}

ensure_wine_config() {
    local wine_prefix="$HOME_DIR/.wine" font_source font_destination font
    local marker marker_tmp

    ensure_packages "${WINE_CONFIG_PACKAGES[@]}"
    if ! wine_prefix_core_satisfied; then
        log "Initializing and validating the Wine prefix for $TARGET_USER..."
        if ! as_user env HOME="$HOME_DIR" WINEPREFIX="$wine_prefix" \
            WINEDLLOVERRIDES=mscoree,mshtml= \
            timeout 180s wineboot -u; then
            error "wineboot failed to initialize $wine_prefix."
            stop_wine_server "$wine_prefix" >/dev/null 2>&1 || true
            return 1
        fi
        if ! as_user env HOME="$HOME_DIR" WINEPREFIX="$wine_prefix" \
            timeout 120s wineserver -w; then
            error "wineserver did not finish Wine prefix initialization: $wine_prefix"
            stop_wine_server "$wine_prefix" >/dev/null 2>&1 || true
            return 1
        fi
        if ! wine_prefix_payload_satisfied; then
            error "wineboot returned success but left an incomplete prefix: $wine_prefix"
            stop_wine_server "$wine_prefix" >/dev/null 2>&1 || true
            return 1
        fi
        if ! as_user env HOME="$HOME_DIR" WINEPREFIX="$wine_prefix" \
            WINEDEBUG=-all timeout 120s wine cmd /c ver >/dev/null 2>&1; then
            error "Wine command smoke test failed for prefix: $wine_prefix"
            stop_wine_server "$wine_prefix" >/dev/null 2>&1 || true
            return 1
        fi
        marker="$wine_prefix/$WINE_PREFIX_COMPLETION_MARKER"
        marker_tmp=$(mktemp)
        printf 'schema=1\n' > "$marker_tmp"
        if ! install_if_changed "$marker_tmp" "$marker" 644; then
            rm -f -- "$marker_tmp"
            return 1
        fi
        rm -f -- "$marker_tmp"
        chown "$TARGET_USER:" "$marker"
    fi

    font_source="$WINDOWS_FONT_SOURCE"
    font_destination="$wine_prefix/drive_c/windows/Fonts"
    if [ -d "$font_source" ]; then
        as_user mkdir -p "$font_destination"
        while IFS= read -r -d '' font; do
            install_if_changed "$font" "$font_destination/$(basename "$font")" 644
            chown "$TARGET_USER:" \
                "$font_destination/$(basename "$font")"
        done < <(find "$font_source" -maxdepth 1 -type f -print0)
    fi
    command -v wineserver >/dev/null 2>&1 || {
        error "Wine package did not provide wineserver for $TARGET_USER."
        return 1
    }
    stop_wine_server "$wine_prefix" || return
    return 0
}

ensure_lutris_config() {
    ensure_packages "${LUTRIS_CONFIG_PACKAGES[@]}"
}

ensure_native_steam_locale() {
    local desktop_file="$APPLICATION_DESKTOP_DIR/steam.desktop" temporary

    steam_native_locale_satisfied && return 0
    [ -f "$desktop_file" ] || die "Steam desktop file is missing: $desktop_file"
    temporary=$(mktemp)
    sed -E \
        's#^Exec=(/usr/bin/steam|steam)#Exec=env LANG=zh_CN.UTF-8 \1#' \
        "$desktop_file" > "$temporary"
    install_if_changed "$temporary" "$desktop_file" 644
    rm -f "$temporary"
    steam_native_locale_satisfied
}

ensure_flatpak_steam_locale() {
    local scope=system status=0

    steam_flatpak_locale_satisfied && return 0
    if platform_is_fedora; then
        scope=$(fedora_flatpak_app_scope com.valvesoftware.Steam \
            "$TARGET_USER" "$HOME_DIR") || status=$?
        [ "$status" -eq 0 ] || return "$status"
    fi
    if [ "$scope" = user ]; then
        fedora_flatpak_user_override_apply \
            com.valvesoftware.Steam "$TARGET_USER" "$HOME_DIR" \
            --env=LANG=zh_CN.UTF-8
    else
        flatpak override --system --env=LANG=zh_CN.UTF-8 \
            com.valvesoftware.Steam
    fi
    steam_flatpak_locale_satisfied
}

ensure_lazyvim_config() {
    local config_dir="$HOME_DIR/.config/nvim" backup_path

    lazyvim_config_satisfied && return 0
    if [ -e "$config_dir" ]; then
        backup_path="$HOME_DIR/.config/nvim.old.apps"
        [ ! -e "$backup_path" ] ||
            backup_path="$HOME_DIR/.config/nvim.old.apps.$(date +%s)"
        warn "Incomplete Neovim configuration moved to $backup_path"
        mv "$config_dir" "$backup_path"
    fi
    if ! as_user git clone https://github.com/LazyVim/starter "$config_dir"; then
        error 'Failed to clone the LazyVim starter.'
        return 1
    fi
    if ! as_user git -C "$config_dir" checkout --detach \
        "$LAZYVIM_STARTER_COMMIT"; then
        error "Pinned LazyVim starter commit is unavailable: $LAZYVIM_STARTER_COMMIT"
        find "$config_dir" -depth -delete
        return 1
    fi
    printf '%s\n' "$LAZYVIM_STARTER_COMMIT" > \
        "$config_dir/.shorin-starter-commit"
    chown "$TARGET_USER:" "$config_dir/.shorin-starter-commit"
    [ ! -d "$config_dir/.git" ] || find "$config_dir/.git" -depth -delete
    lazyvim_config_satisfied
}

ensure_application_nodisplay() {
    local entry=$1 file temporary

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ ! -f "$file" ] && continue
        desktop_entry_key_matches "$file" NoDisplay true && continue
        temporary=$(mktemp)
        awk '
            /^\[Desktop Entry\]$/ {
                print
                print "NoDisplay=true"
                in_desktop=1
                next
            }
            /^\[/ { in_desktop=0 }
            in_desktop && /^NoDisplay=/ { next }
            { print }
        ' "$file" > "$temporary"
        install_if_changed "$temporary" "$file" 644
        rm -f "$temporary"
    done < <(application_nodisplay_files "$entry")
    application_nodisplay_satisfied "$entry"
}

ensure_firefox_defaults_once() {
    install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
        "$HOME_DIR/.mozilla"
    deploy_user_tree_once "$FIREFOX_DEFAULT_SOURCE" \
        "$HOME_DIR/.mozilla" "$TARGET_USER"
}

ensure_vicinae_config_directory() {
    local directory target_group

    directory=$(vicinae_config_directory_path)
    target_group=$(id -gn "$TARGET_USER")
    [ -L "$directory" ] && return 0
    if [ -e "$directory" ] && [ ! -d "$directory" ]; then
        die "Vicinae configuration path is not a directory: $directory"
    fi
    if [ ! -d "$directory" ]; then
        install -d -o "$TARGET_USER" -g "$target_group" "$directory"
    else
        chown "$TARGET_USER:$target_group" "$directory"
        chmod u+rwx "$directory"
    fi
    vicinae_config_directory_satisfied
}

ensure_vicinae_settings() {
    local destination target_group temporary

    destination=$(vicinae_settings_path)
    target_group=$(id -gn "$TARGET_USER")
    ensure_vicinae_config_directory
    [ -L "$destination" ] && return 0
    if [ -e "$destination" ]; then
        [ -f "$destination" ] ||
            die "Vicinae settings path is not a regular file: $destination"
        chown "$TARGET_USER:$target_group" "$destination"
        chmod u+r "$destination"
        vicinae_settings_target_readable "$destination" ||
            die "Vicinae settings are not readable by $TARGET_USER: $destination"
        if vicinae_settings_matches_template "$destination"; then
            chmod 600 "$destination"
            vicinae_settings_satisfied
            return
        fi
        if ! vicinae_settings_is_legacy_shell "$destination"; then
            vicinae_settings_satisfied
            return
        fi
    fi

    temporary=$(mktemp)
    if ! render_vicinae_settings > "$temporary"; then
        rm -f "$temporary"
        error "Cannot render the Vicinae settings template."
        return 1
    fi
    if ! install_if_changed "$temporary" "$destination" 600; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$TARGET_USER:$target_group" "$destination"
    vicinae_settings_satisfied
}

ensure_application_entry_config() {
    local entry=$1 status=0

    case "$entry" in
        wine) ensure_wine_config || status=$? ;;
        lutris) ensure_lutris_config || status=$? ;;
        steam)
            if platform_is_fedora; then
                ensure_flatpak_steam_locale || status=$?
            else
                ensure_native_steam_locale || status=$?
            fi
            ;;
        flatpak:com.valvesoftware.Steam)
            ensure_flatpak_steam_locale || status=$?
            ;;
        lazyvim) ensure_lazyvim_config || status=$? ;;
        firefox) ensure_firefox_defaults_once || status=$? ;;
        AUR:vicinae|AUR:vicinae-bin)
            ensure_vicinae_settings || status=$?
            ;;
    esac
    [ "$status" -eq 0 ] || return "$status"
    ensure_application_nodisplay "$entry"
}

converge_application_configs() {
    local entries=$1 entry entry_status status=0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        entry_status=0
        ensure_application_entry_config "$entry" || entry_status=$?
        [ "$entry_status" -eq 0 ] && continue

        error "Failed to configure application: $entry"
        if declare -p FAILED_PACKAGES >/dev/null 2>&1; then
            FAILED_PACKAGES+=("config:$entry")
        fi
        status=1
    done <<< "$entries"
    return "$status"
}
