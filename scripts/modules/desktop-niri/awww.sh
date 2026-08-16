#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora does not currently ship awww in the enabled repositories.  The
# upstream project publishes source archives from Codeberg, so the Fedora
# path uses one pinned official release and verifies its digest before a
# target-user Cargo build.  Keep this contract independent from DNF package
# mapping: a missing binary must remain drift, never a false success.
AWWW_VERSION=${AWWW_VERSION:-v0.12.1}
AWWW_SOURCE_COMMIT=${AWWW_SOURCE_COMMIT:-f66e12a76dbc4c669b2f1375f78bce49f5b19d66}
AWWW_SOURCE_URL=${AWWW_SOURCE_URL:-https://codeberg.org/LGFae/awww/archive/${AWWW_SOURCE_COMMIT}.tar.gz}
AWWW_SOURCE_SHA256=${AWWW_SOURCE_SHA256:-97b3f1c6d65d9d30e51b17092a45244f8c8549607c9207f3c98d82b28ba18fca}

fedora_awww_bin_dir() {
    local home=${1:-${HOME_DIR:-}}

    [ -n "$home" ] || return 1
    printf '%s\n' "$home/.local/bin"
}

fedora_awww_satisfied() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}
    local bin_dir binary version expected_version

    if [ -n "$home" ]; then
        bin_dir=$(fedora_awww_bin_dir "$home") || return 1
        expected_version=${AWWW_VERSION#v}
        for binary in awww awww-daemon; do
            [ -x "$bin_dir/$binary" ] || return 1
            version=$("$bin_dir/$binary" --version 2>/dev/null) || return 1
            [ "$version" = "$binary $expected_version" ] || return 1
        done
        return 0
    fi

    command -v awww >/dev/null 2>&1 || return 1
    command -v awww-daemon >/dev/null 2>&1
}

fedora_awww_source_contract_valid() {
    case "$AWWW_SOURCE_URL" in
        https://codeberg.org/LGFae/awww/archive/*.tar.gz) ;;
        *)
            error "Refusing a non-official awww source URL: $AWWW_SOURCE_URL"
            return 1
            ;;
    esac
    [[ "$AWWW_SOURCE_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || {
        error 'The pinned awww source digest is not a SHA-256 value.'
        return 1
    }
}

fedora_install_awww() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}
    local group archive build_root source_dir bin_dir binary

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || {
        error 'Fedora awww requires an existing target user and home directory.'
        return 1
    }
    fedora_awww_source_contract_valid || return
    fedora_awww_satisfied "$user" "$home" && return 0
    command -v curl >/dev/null 2>&1 || {
        error 'curl is required to fetch the pinned official awww source archive.'
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        error 'sha256sum is required to verify the pinned official awww source archive.'
        return 1
    }
    command -v tar >/dev/null 2>&1 || {
        error 'tar is required to unpack the pinned official awww source archive.'
        return 1
    }
    command -v runuser >/dev/null 2>&1 || {
        error 'runuser is required to build awww as the target user.'
        return 1
    }

    ensure_packages cargo rust wayland-devel wayland-protocols-devel \
        pkgconf-pkg-config lz4-devel curl || return
    group=$(id -gn "$user") || {
        error "Unable to resolve the primary group for target user $user."
        return 1
    }
    install -d -m 755 -o "$user" -g "$group" \
        "$home/.cache/shorin-arch-setup"
    build_root=$(mktemp -d "$home/.cache/shorin-arch-setup/awww-build.XXXXXX")
    chown "$user:$group" "$build_root"
    archive=$(mktemp)
    if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$AWWW_SOURCE_URL" -o "$archive"; then
        rm -f "$archive"
        error "Unable to download the pinned official awww source archive: $AWWW_SOURCE_URL"
        error "The build directory was preserved for diagnosis: $build_root"
        return 1
    fi
    if ! printf '%s  %s\n' "$AWWW_SOURCE_SHA256" "$archive" |
        sha256sum -c - >/dev/null 2>&1; then
        rm -f "$archive"
        error "The downloaded awww source archive failed SHA-256 verification: $AWWW_SOURCE_URL"
        error "The build directory was preserved for diagnosis: $build_root"
        return 1
    fi
    if ! tar -xzf "$archive" -C "$build_root"; then
        rm -f "$archive"
        error "Unable to unpack the verified awww source archive."
        error "The build directory was preserved for diagnosis: $build_root"
        return 1
    fi
    rm -f "$archive"
    source_dir=$(find "$build_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$source_dir" ] || {
        error "The verified awww source archive did not contain a source directory."
        error "The build directory was preserved for diagnosis: $build_root"
        return 1
    }
    chown -R "$user:$group" "$source_dir"
    if ! runuser -u "$user" -- env HOME="$home" \
        CARGO_HOME="$home/.cargo" bash -c \
        'cd "$1" && cargo build --release' -- "$source_dir"; then
        error "The pinned official awww source failed to build with Cargo."
        error "The build directory was preserved for diagnosis: $build_root"
        return 1
    fi
    bin_dir=$(fedora_awww_bin_dir "$home")
    install -d -m 755 -o "$user" -g "$group" "$bin_dir"
    for binary in awww awww-daemon; do
        [ -x "$source_dir/target/release/$binary" ] || {
            error "The verified awww build did not produce target/release/$binary."
            error "The build directory was preserved for diagnosis: $build_root"
            return 1
        }
        install -m 755 -o "$user" -g "$group" \
            "$source_dir/target/release/$binary" "$bin_dir/$binary"
    done
    fedora_awww_satisfied "$user" "$home" || {
        error "awww installation completed without both target-user commands: $bin_dir"
        error "The build directory was preserved for diagnosis: $build_root"
        return 1
    }
}
