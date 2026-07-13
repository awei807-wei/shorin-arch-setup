#!/bin/bash

# ==============================================================================
# 99-github-apps.sh - Build and install custom GitHub applications
# ==============================================================================

github_app_dependencies() {
    case "$1" in
        focus-shift)
            echo "base-devel git rust gtk4 pkgconf"
            ;;
        niri-clip)
            echo "base-devel git rust gtk4 gtk4-layer-shell sqlite wayland wayland-protocols wtype"
            ;;
        *)
            return 1
            ;;
    esac
}

_normalize_github_url() {
    local url="${1%/}"
    echo "${url%.git}"
}

_sync_github_app_repo() {
    local repo_url="$1"
    local source_name="$2"
    local source_root="$HOME_DIR/.local/src"
    local source_dir="$source_root/$source_name"

    as_user mkdir -p "$source_root"

    if [ -e "$source_dir" ] && [ ! -d "$source_dir/.git" ]; then
        error "Cannot update $source_name: $source_dir exists but is not a Git repository."
        return 1
    fi

    if [ -d "$source_dir/.git" ]; then
        local current_remote
        current_remote=$(as_user git -C "$source_dir" remote get-url origin) || {
            error "Cannot read the origin remote for $source_name."
            return 1
        }

        if [ "$(_normalize_github_url "$current_remote")" != "$(_normalize_github_url "$repo_url")" ]; then
            error "Refusing to update $source_dir because its origin is $current_remote."
            return 1
        fi

        log "Updating GitHub source: $source_name ..."
        if ! as_user env HOME="$HOME_DIR" git -C "$source_dir" pull --ff-only origin main; then
            error "Failed to update $source_name from GitHub."
            return 1
        fi
    else
        log "Cloning GitHub source: $source_name ..."
        if ! as_user env HOME="$HOME_DIR" git clone --branch main --single-branch "$repo_url" "$source_dir"; then
            error "Failed to clone $source_name from GitHub."
            return 1
        fi
    fi

    GITHUB_APP_SOURCE_DIR="$source_dir"
}

_build_and_install_cargo_binary() {
    local source_dir="$1"
    local binary_name="$2"
    local destination="$HOME_DIR/.local/bin/$binary_name"

    log "Building $binary_name from source ..."
    if ! as_user env HOME="$HOME_DIR" cargo build \
        --manifest-path "$source_dir/Cargo.toml" \
        --release \
        --locked; then
        error "Cargo build failed for $binary_name."
        return 1
    fi

    if ! as_user install -Dm755 "$source_dir/target/release/$binary_name" "$destination"; then
        error "Failed to install $binary_name to $destination."
        return 1
    fi
}

_install_focus_shift() {
    _sync_github_app_repo \
        "https://github.com/awei807-wei/FocusShift.git" \
        "focus-shift" || return 1

    _build_and_install_cargo_binary "$GITHUB_APP_SOURCE_DIR" "focus-shift"
}

_install_niri_clip() {
    _sync_github_app_repo \
        "https://github.com/awei807-wei/niri-clip.git" \
        "niri-clip" || return 1

    _build_and_install_cargo_binary "$GITHUB_APP_SOURCE_DIR" "niri-clip" || return 1

    local user_service_dir="$HOME_DIR/.config/systemd/user"
    local service_file="$user_service_dir/niri-clip.service"
    local wants_dir="$user_service_dir/graphical-session.target.wants"
    local user_id
    local runtime_dir

    if ! as_user install -Dm644 \
        "$GITHUB_APP_SOURCE_DIR/systemd/niri-clip.service" \
        "$service_file"; then
        error "Failed to install the niri-clip user service."
        return 1
    fi

    as_user mkdir -p "$wants_dir"
    if ! as_user ln -sfn "../niri-clip.service" "$wants_dir/niri-clip.service"; then
        error "Failed to enable the niri-clip user service."
        return 1
    fi

    user_id=$(id -u "$TARGET_USER")
    runtime_dir="/run/user/$user_id"
    if [ -S "$runtime_dir/bus" ]; then
        if ! as_user env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            systemctl --user daemon-reload; then
            warn "niri-clip was installed, but the active user service manager could not reload."
        fi
    else
        log "niri-clip is enabled and will start with the next graphical session."
    fi
}

install_github_app() {
    local app="$1"

    case "$app" in
        focus-shift)
            _install_focus_shift
            ;;
        niri-clip)
            _install_niri_clip
            ;;
        *)
            error "Unsupported GitHub application: $app"
            return 1
            ;;
    esac
}
