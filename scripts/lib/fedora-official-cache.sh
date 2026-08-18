#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

if [ "${SHORIN_FEDORA_OFFICIAL_CACHE_LOADED:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi
SHORIN_FEDORA_OFFICIAL_CACHE_LOADED=1

FEDORA_OFFICIAL_DEFAULT_CACHE_RELATIVE='.cache/shorin-arch-setup/fedora-applications'
FEDORA_OFFICIAL_CACHE_IS_MANAGED=0
FEDORA_OFFICIAL_CACHE_OWNER=''
FEDORA_OFFICIAL_CACHE_GROUP=''

# Prepare an official-artifact cache without ever changing metadata on an
# existing caller-provided directory.  The default cache below the target
# user's home is the only cache owned by this project; an explicit
# FEDORA_OFFICIAL_CACHE_DIR is always treated as external, even when it
# happens to point at the same path.
fedora_prepare_official_cache_dir() {
    local cache_dir=$1 target_user=${2:-${TARGET_USER:-}}
    local home=${3:-${HOME_DIR:-}} component current next path
    local managed=0 group=''
    local -a components=()

    FEDORA_OFFICIAL_CACHE_IS_MANAGED=0
    FEDORA_OFFICIAL_CACHE_OWNER=''
    FEDORA_OFFICIAL_CACHE_GROUP=''

    [ -n "$cache_dir" ] || {
        error 'Fedora official cache directory must not be empty.'
        return 1
    }
    if [ -n "$home" ] && [ -z "${FEDORA_OFFICIAL_CACHE_DIR:-}" ] &&
        [ "$cache_dir" = "$home/$FEDORA_OFFICIAL_DEFAULT_CACHE_RELATIVE" ]; then
        managed=1
        [ -n "$target_user" ] || {
            error 'Unable to resolve the target user for the managed Fedora official cache.'
            return 1
        }
        group=$(id -gn "$target_user") || {
            error "Unable to resolve the primary group for target user $target_user."
            return 1
        }
        [ -n "$group" ] || {
            error "Unable to resolve the primary group for target user $target_user."
            return 1
        }
    fi

    # Walk every path component.  Checking only the leaf would allow an
    # existing symlink in a parent to redirect mkdir/chown into an unrelated
    # tree.  Existing components are inspected but never chmod/chowned unless
    # the final path is the exact project-managed default cache.
    path=$cache_dir
    case "$path" in
        /)  error 'Fedora official cache directory must not be the filesystem root.'; return 1 ;;
        /*) current=/; path=${path#/} ;;
        *)  current=.; ;;
    esac
    IFS=/ read -r -a components <<< "$path"
    [ "${#components[@]}" -gt 0 ] || {
        error "Invalid Fedora official cache directory: $cache_dir"
        return 1
    }
    for component in "${components[@]}"; do
        [ -n "$component" ] || continue
        case "$component" in
            .|..)
                error "Fedora official cache directory contains an unsafe path component: $cache_dir"
                return 1
                ;;
        esac
        if [ "$current" = / ]; then
            next="/$component"
        else
            next="$current/$component"
        fi
        if [ -L "$next" ]; then
            error "Refusing symlink in Fedora official cache path: $next"
            return 1
        fi
        if [ -e "$next" ]; then
            [ -d "$next" ] || {
                error "Fedora official cache path is not a directory: $next"
                return 1
            }
        else
            mkdir -m 755 -- "$next" || {
                error "Unable to create Fedora official cache directory: $next"
                return 1
            }
            # mkdir is affected by the caller's umask; make only a newly
            # created directory deterministic.  Existing external metadata
            # is deliberately left untouched.
            chmod 755 -- "$next" || {
                error "Unable to set mode on new Fedora official cache directory: $next"
                return 1
            }
            if [ "$managed" -eq 1 ]; then
                chown "$target_user:$group" -- "$next" || {
                    error "Unable to assign managed Fedora official cache ownership: $next"
                    return 1
                }
            fi
        fi
        current=$next
    done

    if [ "$managed" -eq 1 ]; then
        # This is the exact project-managed leaf.  Repairing its mode/owner is
        # safe; no recursive operation is used and no external path reaches
        # this branch.
        chmod 755 -- "$current" || {
            error "Unable to set managed Fedora official cache mode: $current"
            return 1
        }
        chown "$target_user:$group" -- "$current" || {
            error "Unable to assign managed Fedora official cache ownership: $current"
            return 1
        }
        FEDORA_OFFICIAL_CACHE_IS_MANAGED=1
        FEDORA_OFFICIAL_CACHE_OWNER=$target_user
        FEDORA_OFFICIAL_CACHE_GROUP=$group
    fi
}

fedora_official_repair_managed_artifact_metadata() {
    local file=$1

    [ "${FEDORA_OFFICIAL_CACHE_IS_MANAGED:-0}" -eq 1 ] || return 0
    chmod 644 -- "$file" || {
        error "Unable to set managed Fedora official artifact mode: $file"
        return 1
    }
    chown "$FEDORA_OFFICIAL_CACHE_OWNER:$FEDORA_OFFICIAL_CACHE_GROUP" -- "$file" || {
        error "Unable to assign managed Fedora official artifact ownership: $file"
        return 1
    }
}
