#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora target-user Starship provider.

fedora_provider_architecture() {
    uname -m
}

fedora_provider_architecture_satisfied() {
    local architecture

    architecture=$(fedora_provider_architecture) || return 2
    [ "$architecture" = x86_64 ] || {
        error "Fedora target-user providers support x86_64 only (detected $architecture)."
        return 1
    }
}

fedora_target_user_exec() {
    local user=$1 home=$2 target_uid current_uid target_path
    shift 2

    [ -n "$user" ] && [ -n "$home" ] || return 2
    target_uid=$(id -u "$user" 2>/dev/null) || return 2
    current_uid=$(id -u 2>/dev/null) || return 2
    if [ "$target_uid" = "$current_uid" ]; then
        target_path=${PATH:-/usr/local/bin:/usr/bin:/bin}
        target_path="$home/.local/bin:$target_path"
        HOME="$home" XDG_DATA_HOME="$home/.local/share" \
            PATH="$target_path" "$@"
    else
        command -v runuser >/dev/null 2>&1 || return 2
        target_path="$home/.local/bin:/usr/local/bin:/usr/bin:/bin"
        runuser -u "$user" -- env HOME="$home" \
            XDG_DATA_HOME="$home/.local/share" PATH="$target_path" "$@"
    fi
}

fedora_target_user_command_path() {
    local user=$1 home=$2 command_name=$3 output status=0

    output=$(fedora_target_user_exec "$user" "$home" /bin/sh -c \
        'command -v "$1"' sh "$command_name" 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    output=${output%%$'\n'*}
    case "$output" in
        /*) [ -x "$output" ] && printf '%s\n' "$output" ;;
        *) return 1 ;;
    esac
}

fedora_target_user_provider_file_contract() {
    local path=$1 user=$2 home=$3 expected_mode=$4 uid gid owner mode font_dir

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    uid=$(id -u "$user" 2>/dev/null) || return 2
    gid=$(id -g "$user" 2>/dev/null) || return 2
    owner=$(stat -c '%u:%g' "$path" 2>/dev/null) || return 2
    mode=$(stat -c '%a' "$path" 2>/dev/null) || return 2
    [ "$owner" = "$uid:$gid" ] && [ "$mode" = "$expected_mode" ] || return 1
    case "$path" in
        "$home/.local/bin/starship") return 0 ;;
        "$home/.local/share/fonts/$FEDORA_SHORIN_FONT_DIR_NAME"/*)
            font_dir="$home/.local/share/fonts/$FEDORA_SHORIN_FONT_DIR_NAME"
            [ -d "$font_dir" ] && [ ! -L "$font_dir" ] || return 1
            owner=$(stat -c '%u:%g' "$font_dir" 2>/dev/null) || return 2
            mode=$(stat -c '%a' "$font_dir" 2>/dev/null) || return 2
            [ "$owner" = "$uid:$gid" ] && [ "$mode" = 755 ] || return 1
            return 0
            ;;
        *) return 0 ;;
    esac
}

fedora_starship_binary_path() {
    local home=${2:-${HOME_DIR:-}}

    [ -n "$home" ] || return 1
    printf '%s\n' "$home/.local/bin/$1"
}
fedora_starship_source_contract_valid() {
    [ "$FEDORA_STARSHIP_VERSION" = "$FEDORA_STARSHIP_VERSION_PINNED" ] || {
        error "Starship version is not the pinned release: $FEDORA_STARSHIP_VERSION"
        return 1
    }
    [ "$FEDORA_STARSHIP_URL" = "$FEDORA_STARSHIP_URL_PINNED" ] || {
        error "Refusing a non-official Starship source URL: $FEDORA_STARSHIP_URL"
        return 1
    }
    [ "$FEDORA_STARSHIP_SHA256" = "$FEDORA_STARSHIP_SHA256_PINNED" ] || {
        error 'The Starship digest does not match the pinned release.'
        return 1
    }
}

fedora_starship_command_path() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}

    fedora_target_user_command_path "$user" "$home" starship
}

fedora_starship_command_satisfied() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}
    local command_path output status=0

    command_path=$(fedora_starship_command_path "$user" "$home") || return $?
    case "$command_path" in
        "$home/.local/bin/starship")
            fedora_target_user_provider_file_contract \
                "$command_path" "$user" "$home" 755 || return
            ;;
    esac
    output=$(fedora_target_user_exec "$user" "$home" \
        "$command_path" --version 2>/dev/null) || {
        status=$?
        [ "$status" -gt 1 ] || status=1
        return "$status"
    }
    # An existing user-managed command is valid even when its version is not
    # the pinned installer version.  The provider only installs the pinned
    # release when no usable command is already available.
    grep -Eiq '(^|[[:space:]])starship[[:space:]]+[0-9]+([.][0-9]+){1,2}([[:space:]]|$)' <<< "$output"
}

fedora_starship_target_satisfied() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}

    [ -n "$user" ] && [ -n "$home" ] || return 2
    fedora_starship_command_satisfied "$user" "$home"
}

fedora_starship_satisfied() {
    fedora_starship_target_satisfied "$@"
}

fedora_starship_archive_entries_safe() {
    local archive=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local entries details entry normalized type

    if [ -n "$user" ] && [ -n "$home" ] && id -u "$user" >/dev/null 2>&1; then
        fedora_target_user_command_path "$user" "$home" tar >/dev/null ||
            return 2
        entries=$(fedora_target_user_exec "$user" "$home" \
            tar -tzf "$archive" 2>/dev/null) || return 1
        details=$(fedora_target_user_exec "$user" "$home" \
            tar -tvzf "$archive" 2>/dev/null) || return 1
    else
        command -v tar >/dev/null 2>&1 || return 2
        entries=$(tar -tzf "$archive" 2>/dev/null) || return 1
        details=$(tar -tvzf "$archive" 2>/dev/null) || return 1
    fi
    [ -n "$entries" ] || return 1
    while IFS= read -r details; do
        type=${details:0:1}
        [ "$type" = - ] || return 1
    done <<< "$details"
    while IFS= read -r entry; do
        [ -n "$entry" ] || return 1
        normalized=${entry#./}
        case "$normalized" in
            starship) ;;
            /*|[A-Za-z]:/*|[A-Za-z]:\\*|../*|*/../*|*/..|..)
                return 1
                ;;
            *) return 1 ;;
        esac
    done <<< "$entries"
}

_fedora_install_starship_unlocked() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}
    local group archive work extract source destination staged status=0 command_name
    local written_identity='' staged_identity=''

    FEDORA_PROVIDER_LAST_WRITTEN_STARSHIP=''

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || {
        error 'Fedora Starship requires a target user and home directory.'
        return 1
    }
    fedora_starship_target_satisfied "$user" "$home" && return 0
    fedora_starship_source_contract_valid || return
    destination=$(fedora_starship_binary_path starship "$home") || return 1
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        error "Refusing to overwrite an existing unusable Starship command: $destination"
        return 1
    fi
    for command_name in curl sha256sum tar; do
        fedora_target_user_command_path "$user" "$home" "$command_name" \
            >/dev/null || {
                error "$command_name is not available in the target user's environment."
                return 2
            }
    done
    group=$(id -gn "$user" 2>/dev/null) || {
        error "Unable to resolve the primary group for target user $user."
        return 2
    }
    work=$(mktemp -d "${TMPDIR:-/tmp}/shorin-starship.XXXXXX") || return 1
    chown "$user:$group" "$work" 2>/dev/null || {
        [ "$(id -u)" = "$(id -u "$user" 2>/dev/null)" ] || {
            rm -rf "$work"
            return 1
        }
    }
    chmod 700 "$work"
    archive="$work/starship.tar.gz"
    extract="$work/extract"
    fedora_target_user_exec "$user" "$home" mkdir -p "$extract" || {
        rm -rf "$work"
        return 1
    }
    if ! fedora_target_user_exec "$user" "$home" \
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$FEDORA_STARSHIP_URL" -o "$archive"; then
        rm -rf "$work"
        error "Unable to download the pinned Starship release: $FEDORA_STARSHIP_URL"
        return 1
    fi
    if ! fedora_target_user_exec "$user" "$home" sha256sum -c - \
        <<< "${FEDORA_STARSHIP_SHA256}  ${archive}" >/dev/null 2>&1; then
        rm -rf "$work"
        error "The downloaded Starship release failed SHA-256 verification: $FEDORA_STARSHIP_URL"
        return 1
    fi
    if ! fedora_starship_archive_entries_safe "$archive" "$user" "$home"; then
        rm -rf "$work"
        error 'The Starship release contains an unsafe or unexpected archive entry.'
        return 1
    fi
    if ! fedora_target_user_exec "$user" "$home" \
        tar --extract --gzip --file "$archive" --directory "$extract" \
        --no-same-owner --no-same-permissions; then
        rm -rf "$work"
        error 'Unable to unpack the verified Starship release.'
        return 1
    fi
    rm -f "$archive"
    source="$extract/starship"
    if [ ! -f "$source" ] || [ -L "$source" ] || [ ! -x "$source" ]; then
        rm -rf "$work"
        error 'The verified Starship release did not contain a regular executable.'
        return 1
    fi
    install -d -m 755 -o "$user" -g "$group" "$(dirname "$destination")" || {
        rm -rf "$work"
        return 1
    }
    staged=$(mktemp "$(dirname "$destination")/.starship.XXXXXX") || {
        rm -rf "$work"
        return 1
    }
    if ! install -m 755 -o "$user" -g "$group" "$source" "$staged"; then
        rm -f "$staged"
        rm -rf "$work"
        return 1
    fi
    staged_identity=$(fedora_provider_file_identity "$staged") || {
        rm -f "$staged"
        rm -rf "$work"
        error 'Unable to record the staged Starship identity.'
        return 1
    }
    # A user may have installed a command while the network transaction was
    # in progress.  Never replace it; discard our staged copy instead.
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        rm -f "$staged"
        rm -rf "$work"
        error "Refusing to replace a Starship command created during installation: $destination"
        return 1
    fi
    if ! ln "$staged" "$destination"; then
        rm -f "$staged"
        rm -rf "$work"
        error "Refusing to replace a Starship command created during installation: $destination"
        return 1
    fi
    rm -f -- "$staged"
    written_identity=$(fedora_provider_file_identity "$destination") || {
        error "Unable to record the installed Starship identity: $destination"
        rm -rf "$work"
        return 1
    }
    if [ "$written_identity" != "$staged_identity" ]; then
        error "Starship destination changed during installation; preserving the concurrent file: $destination"
        rm -rf "$work"
        return 2
    fi
    FEDORA_PROVIDER_LAST_WRITTEN_STARSHIP="$destination|$written_identity"
    rm -rf "$work"
    if fedora_starship_target_satisfied "$user" "$home"; then
        return 0
    else
        status=$?
    fi
    # Remove only the exact inode/digest written by this provider.  A user
    # replacement made during post-install checks must be preserved.
    fedora_provider_remove_if_unchanged "$destination" "$written_identity" ||
        status=2
    error "Installed Starship did not pass the target-user command/version contract: $destination"
    return "$status"
}

fedora_install_starship() {
    platform_is_fedora || return 0
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}} status

    require_writable_mode || return
    fedora_provider_architecture_satisfied || return
    fedora_provider_lock_acquire || return
    _fedora_install_starship_unlocked "$user" "$home" || status=$?
    status=${status:-0}
    fedora_provider_lock_release
    return "$status"
}
