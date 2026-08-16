#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 99-github-apps.sh - Build and install custom GitHub applications
# ==============================================================================

github_app_dependencies() {
    if platform_is_fedora; then
        case "$1" in
            focus-shift)
                # Fedora splits the development headers and pkg-config files
                # out of the runtime packages.  In particular, gtk4-devel
                # alone does not make the gio/glib/gobject/pango checks in
                # FocusShift's build environment explicit, so keep those
                # contracts here instead of letting Cargo fail later with a
                # misleading missing-system-library error.
                echo "base-devel git cargo rust glib2-devel pango-devel cairo-devel cairo-gobject-devel gtk4-devel gdk-pixbuf2-devel graphene-devel pkgconf-pkg-config"
                ;;
            niri-clip)
                echo "base-devel git cargo rust glib2-devel pango-devel cairo-devel cairo-gobject-devel gtk4-devel gdk-pixbuf2-devel graphene-devel gtk4-layer-shell-devel sqlite-devel pkgconf-pkg-config wayland-devel wayland-protocols-devel wtype"
                ;;
            *)
                return 1
                ;;
        esac
        return 0
    fi

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
    local expected_commit="$3"
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
        if ! as_user env HOME="$HOME_DIR" git -C "$source_dir" fetch origin main ||
            ! as_user git -C "$source_dir" cat-file -e "$expected_commit^{commit}" ||
            ! as_user git -C "$source_dir" checkout --detach "$expected_commit"; then
            error "Failed to update $source_name from GitHub."
            return 1
        fi
    else
        log "Cloning GitHub source: $source_name ..."
        if ! as_user env HOME="$HOME_DIR" git clone --branch main --single-branch "$repo_url" "$source_dir"; then
            error "Failed to clone $source_name from GitHub."
            return 1
        fi
        if ! as_user git -C "$source_dir" checkout --detach "$expected_commit"; then
            error "Pinned commit is unavailable for $source_name: $expected_commit"
            return 1
        fi
    fi

    GITHUB_APP_SOURCE_DIR="$source_dir"
}

_cleanup_github_build_dir() {
    local build_dir=$1

    case "$build_dir" in
        "$HOME_DIR/.cache/shorin-build."*)
            [ ! -e "$build_dir" ] || as_user find "$build_dir" -depth -delete
            ;;
        *)
            error "Refusing to clean an unexpected build directory: $build_dir"
            return 1
            ;;
    esac
}

_build_and_install_cargo_binary() {
    local source_dir="$1"
    local binary_name="$2"
    local destination="$HOME_DIR/.local/bin/$binary_name"
    local provenance_dir=${GITHUB_PROVENANCE_DIR:-$HOME_DIR/.local/share/shorin-arch-setup/github}
    local provenance="$provenance_dir/$binary_name.build"
    local build_dir checkout_head checkout_status binary_sha provenance_tmp

    log "Building $binary_name from source ..."
    as_user mkdir -p "$HOME_DIR/.cache"
    build_dir=$(as_user mktemp -d "$HOME_DIR/.cache/shorin-build.XXXXXX")
    if ! as_user env HOME="$HOME_DIR" cargo build \
        --manifest-path "$source_dir/Cargo.toml" \
        --target-dir "$build_dir" \
        --release \
        --locked; then
        _cleanup_github_build_dir "$build_dir"
        error "Cargo build failed for $binary_name."
        return 1
    fi

    checkout_head=$(as_user git -C "$source_dir" rev-parse HEAD) || {
        _cleanup_github_build_dir "$build_dir"
        error "Cannot determine the source commit for $binary_name."
        return 1
    }
    checkout_status=$(as_user git -C "$source_dir" status --porcelain) || {
        _cleanup_github_build_dir "$build_dir"
        error "Cannot inspect the source checkout for $binary_name."
        return 1
    }
    if [ -n "$checkout_status" ]; then
        _cleanup_github_build_dir "$build_dir"
        error "Refusing to build $binary_name from a modified checkout."
        return 1
    fi
    binary_sha=$(sha256sum "$build_dir/release/$binary_name" | awk '{ print $1 }') || {
        _cleanup_github_build_dir "$build_dir"
        error "Cannot hash the built $binary_name binary."
        return 1
    }
    if ! install_if_changed "$build_dir/release/$binary_name" "$destination" 755; then
        _cleanup_github_build_dir "$build_dir"
        error "Failed to install $binary_name to $destination."
        return 1
    fi
    chown "$TARGET_USER:" "$destination"

    provenance_tmp=$(mktemp)
    printf 'app=%s\ncommit=%s\nsha256=%s\n' \
        "$binary_name" "$checkout_head" "$binary_sha" > "$provenance_tmp"
    if ! install_if_changed "$provenance_tmp" "$provenance" 644; then
        rm -f "$provenance_tmp"
        _cleanup_github_build_dir "$build_dir"
        error "Failed to record the build provenance for $binary_name."
        return 1
    fi
    rm -f "$provenance_tmp"
    chown "$TARGET_USER:" "$provenance"
    _cleanup_github_build_dir "$build_dir"
    github_provenance_satisfied \
        "$binary_name" "$source_dir" "$destination"
}

_install_focus_shift() {
    _sync_github_app_repo \
        "$FOCUS_SHIFT_REPO_URL" \
        "focus-shift" "$FOCUS_SHIFT_COMMIT" || return 1

    _build_and_install_cargo_binary "$GITHUB_APP_SOURCE_DIR" "focus-shift"
}

_install_niri_clip() {
    _sync_github_app_repo \
        "$NIRI_CLIP_REPO_URL" \
        "niri-clip" "$NIRI_CLIP_COMMIT" || return 1

    _build_and_install_cargo_binary "$GITHUB_APP_SOURCE_DIR" "niri-clip" || return 1

    local user_service_dir="$HOME_DIR/.config/systemd/user"
    local service_file="$user_service_dir/niri-clip.service"
    if ! install_if_changed \
        "$GITHUB_APP_SOURCE_DIR/systemd/niri-clip.service" "$service_file" 644; then
        error "Failed to install the niri-clip user service."
        return 1
    fi
    chown "$TARGET_USER:" "$service_file"
    ensure_user_unit_enabled "$TARGET_USER" niri-clip.service graphical-session.target
    verify_user_unit "$TARGET_USER" niri-clip.service graphical-session.target
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
