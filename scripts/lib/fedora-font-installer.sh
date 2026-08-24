#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora exact-family font asset installer.

fedora_shorin_font_dir() {
    local home=${1:-${HOME_DIR:-}}

    [ -n "$home" ] || return 1
    printf '%s\n' "$home/.local/share/fonts/$FEDORA_SHORIN_FONT_DIR_NAME"
}

fedora_font_archive_entries_safe() {
    local archive=$1 format=$2 user=${3:-${TARGET_USER:-}}
    local home=${4:-${HOME_DIR:-}} entries details entry normalized type

    case "$format" in
        nerd)
            if [ -n "$user" ] && [ -n "$home" ] &&
                id -u "$user" >/dev/null 2>&1; then
                fedora_target_user_command_path "$user" "$home" tar >/dev/null ||
                    return 2
                entries=$(fedora_target_user_exec "$user" "$home" \
                    tar -tJf "$archive" 2>/dev/null) || return 1
                details=$(fedora_target_user_exec "$user" "$home" \
                    tar -tvJf "$archive" 2>/dev/null) || return 1
            else
                entries=$(tar -tJf "$archive" 2>/dev/null) || return 1
                details=$(tar -tvJf "$archive" 2>/dev/null) || return 1
            fi
            while IFS= read -r details; do
                type=${details:0:1}
                case "$type" in
                    -|d) ;;
                    *) return 1 ;;
                esac
            done <<< "$details"
            ;;
        maple)
            if [ -n "$user" ] && [ -n "$home" ] &&
                id -u "$user" >/dev/null 2>&1; then
                fedora_target_user_command_path "$user" "$home" unzip >/dev/null ||
                    return 2
                entries=$(fedora_target_user_exec "$user" "$home" \
                    unzip -Z1 "$archive" 2>/dev/null) || return 1
            else
                entries=$(unzip -Z1 "$archive" 2>/dev/null) || return 1
            fi
            ;;
        *) return 1 ;;
    esac
    [ -n "$entries" ] || return 1
    while IFS= read -r entry; do
        [ -n "$entry" ] || return 1
        normalized=${entry#./}
        case "$normalized" in
            /*|[A-Za-z]:/*|[A-Za-z]:\\*|../*|*/../*|*/..|..)
                return 1
                ;;
        esac
    done <<< "$entries"
}

fedora_zip_archive_types_safe() {
    local archive=$1 user=${2:-${TARGET_USER:-}}
    local home=${3:-${HOME_DIR:-}} output

    if [ -n "$user" ] && [ -n "$home" ] && id -u "$user" >/dev/null 2>&1; then
        fedora_target_user_command_path "$user" "$home" unzip >/dev/null ||
            return 2
        output=$(fedora_target_user_exec "$user" "$home" \
            unzip -Z -v "$archive" 2>/dev/null) || return 1
    else
        command -v unzip >/dev/null 2>&1 || return 2
        output=$(unzip -Z -v "$archive" 2>/dev/null) || return 1
    fi
    awk '
            /Unix file attributes .*\):/ {
                line = $0
                sub(/^.*\):[[:space:]]*/, "", line)
                type = substr(line, 1, 1)
                if (type != "-" && type != "d") bad = 1
            }
            END { exit(bad ? 1 : 0) }
        ' <<< "$output"
}

fedora_download_verified_asset() {
    local url=$1 digest=$2 output=$3 user=${4:-${TARGET_USER:-}}
    local home=${5:-${HOME_DIR:-}} expected_size=${6:-} actual_size

    if [ -n "$user" ] && [ -n "$home" ] && id -u "$user" >/dev/null 2>&1; then
        fedora_target_user_exec "$user" "$home" \
            curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            "$url" -o "$output" || return 1
        if [ -n "$expected_size" ]; then
            actual_size=$(fedora_target_user_exec "$user" "$home" \
                stat -c '%s' "$output") || return 1
        fi
    else
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            "$url" -o "$output" || return 1
        if [ -n "$expected_size" ]; then
            actual_size=$(stat -c '%s' "$output") || return 1
        fi
    fi
    if [ -n "$expected_size" ] && [ "$actual_size" != "$expected_size" ]; then
        error "Downloaded asset has size $actual_size bytes; expected $expected_size: $url"
        return 1
    fi
    if [ -n "$user" ] && [ -n "$home" ] && id -u "$user" >/dev/null 2>&1; then
        fedora_target_user_exec "$user" "$home" sha256sum -c - \
            <<< "${digest}  ${output}" >/dev/null 2>&1
    else
        printf '%s  %s\n' "$digest" "$output" |
            sha256sum -c - >/dev/null 2>&1
    fi
}

fedora_nerd_font_file_name_allowed() {
    local name

    name=$(basename "$1")
    [[ "$name" =~ ^JetBrainsMonoNerdFont(Mono|Propo)?-[A-Za-z0-9]+(Italic)?[.]ttf$ ]]
}

fedora_nerd_font_file_name_ignored() {
    local name

    name=$(basename "$1")
    [[ "$name" =~ ^JetBrainsMonoNLNerdFont(Mono|Propo)?-[A-Za-z0-9]+(Italic)?[.]ttf$ ]]
}

fedora_maple_font_file_name_allowed() {
    local name

    name=$(basename "$1")
    [[ "$name" =~ ^JetBrainsMapleMono(-NF)?-[A-Za-z0-9_.-]+[.]ttf$ ]]
}

fedora_mdi_font_file_name_allowed() {
    [ "$(basename "$1")" = materialdesignicons-webfont.ttf ]
}

fedora_collect_font_sources() {
    local target=$1 work=$2 output=$3 user=${4:-${TARGET_USER:-}}
    local home=${5:-${HOME_DIR:-}} archive extract path source
    local maple_ttf_count=0

    fedora_font_source_contract_valid "$target" || return 1
    case "$target" in
        ttf-jetbrains-mono-nerd)
            archive="$work/JetBrainsMono.tar.xz"
            extract="$work/nerd"
            fedora_target_user_exec "$user" "$home" mkdir -p "$extract" ||
                return 1
            fedora_download_verified_asset "$FEDORA_JETBRAINSMONO_NERD_URL" \
                "$FEDORA_JETBRAINSMONO_NERD_SHA256" "$archive" "$user" "$home" || return 1
            fedora_font_archive_entries_safe "$archive" nerd "$user" "$home" || return 1
            fedora_target_user_exec "$user" "$home" \
                tar --extract --xz --file "$archive" --directory "$extract" \
                --no-same-owner --no-same-permissions || return 1
            if find "$extract" -type l -print -quit | grep -q .; then
                return 1
            fi
            while IFS= read -r -d '' path; do
                if fedora_nerd_font_file_name_allowed "$path"; then
                    printf '%s\n' "$path" >> "$output"
                elif fedora_nerd_font_file_name_ignored "$path"; then
                    :
                else
                    return 1
                fi
            done < <(find "$extract" -type f -name '*.ttf' -print0)
            [ -s "$output" ] || return 1
            ;;
        ttf-jetbrains-maple-mono-nf-xx-xx)
            archive="$work/JetBrainsMapleMono.zip"
            extract="$work/maple"
            fedora_target_user_exec "$user" "$home" mkdir -p "$extract" ||
                return 1
            fedora_download_verified_asset "$FEDORA_JETBRAINS_MAPLE_URL" \
                "$FEDORA_JETBRAINS_MAPLE_SHA256" "$archive" "$user" "$home" \
                "$FEDORA_JETBRAINS_MAPLE_SIZE" || return 1
            fedora_font_archive_entries_safe "$archive" maple "$user" "$home" || return 1
            fedora_zip_archive_types_safe "$archive" "$user" "$home" || return 1
            fedora_target_user_exec "$user" "$home" \
                unzip -q "$archive" -d "$extract" || return 1
            if find "$extract" -type l -print -quit | grep -q .; then
                return 1
            fi
            while IFS= read -r -d '' path; do
                fedora_maple_font_file_name_allowed "$path" || return 1
                printf '%s\n' "$path" >> "$output"
                maple_ttf_count=$((maple_ttf_count + 1))
            done < <(find "$extract" -type f -name '*.ttf' -print0)
            [ "$maple_ttf_count" -eq "$FEDORA_JETBRAINS_MAPLE_TTF_COUNT" ] || {
                error "Fusion Maple archive contains $maple_ttf_count TTF files; expected $FEDORA_JETBRAINS_MAPLE_TTF_COUNT."
                return 1
            }
            ;;
        material-design-icons)
            source="$work/materialdesignicons-webfont.ttf"
            fedora_download_verified_asset "$FEDORA_MATERIAL_DESIGN_ICONS_URL" \
                "$FEDORA_MATERIAL_DESIGN_ICONS_SHA256" "$source" "$user" "$home" || return 1
            fedora_mdi_font_file_name_allowed "$source" || return 1
            printf '%s\n' "$source" >> "$output"
            ;;
        *) return 1 ;;
    esac
}

fedora_font_provider_cleanup_installed() {
    local record path expected conflict=0

    while IFS='|' read -r path expected; do
        [ -n "$path" ] || continue
        if ! fedora_provider_remove_if_unchanged "$path" "$expected"; then
            conflict=1
        fi
    done <<< "${FEDORA_PROVIDER_WRITTEN_FILES:-}"
    return "$conflict"
}

_fedora_install_font_provider_targets_unlocked() {
    local user=$1 home=$2
    shift 2
    local group font_dir work source_list target source destination staged \
        status=0 uid gid owner mode written_identity staged_identity cleanup_status
    local created_dir=0 created_dir_identity=''
    local -a needed=() installed_records=()

    FEDORA_PROVIDER_WRITTEN_FILES=''
    FEDORA_PROVIDER_CREATED_FONT_DIR_IDENTITY=''

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || {
        error 'Fedora font providers require a target user and home directory.'
        return 1
    }
    [ "$#" -gt 0 ] || return 0
    for target in "$@"; do
        fedora_font_family_from_target "$target" >/dev/null || {
            error "Unknown Fedora font provider target: $target"
            return 1
        }
        if fedora_font_target_satisfied "$target" "$user" "$home"; then
            continue
        else
            status=$?
        fi
        [ "$status" -eq 1 ] || {
            error "Unable to inspect Fedora font provider target: $target"
            return "$status"
        }
        needed+=("$target")
    done
    [ "${#needed[@]}" -gt 0 ] || return 0
    fedora_target_user_provider_prerequisites_satisfied "$user" "$home" || {
        error 'curl/unzip/xz/tar/flock/fontconfig are not available in the target user environment.'
        return 2
    }
    group=$(id -gn "$user" 2>/dev/null) || return 2
    uid=$(id -u "$user" 2>/dev/null) || return 2
    gid=$(id -g "$user" 2>/dev/null) || return 2
    work=$(mktemp -d "${TMPDIR:-/tmp}/shorin-fonts.XXXXXX") || return 1
    chown "$user:$group" "$work" 2>/dev/null || {
        [ "$(id -u)" = "$(id -u "$user" 2>/dev/null)" ] || {
            rm -rf "$work"
            return 1
        }
    }
    chmod 700 "$work"
    source_list="$work/sources"
    : > "$source_list"
    for target in "${needed[@]}"; do
        if ! fedora_collect_font_sources "$target" "$work" "$source_list" \
            "$user" "$home"; then
            rm -rf "$work"
            error "Unable to download or unpack Fedora font provider target: $target"
            return 1
        fi
    done
    font_dir=$(fedora_shorin_font_dir "$home") || {
        rm -rf "$work"
        return 1
    }
    if [ -L "$font_dir" ] ||
        { [ -e "$font_dir" ] && [ ! -d "$font_dir" ]; }; then
        rm -rf "$work"
        error "Refusing to replace a non-directory Fedora font provider path: $font_dir"
        return 1
    fi
    if [ -d "$font_dir" ]; then
        owner=$(stat -c '%u:%g' "$font_dir" 2>/dev/null) || {
            rm -rf "$work"
            return 2
        }
        mode=$(stat -c '%a' "$font_dir" 2>/dev/null) || {
            rm -rf "$work"
            return 2
        }
        if [ "$owner" != "$uid:$gid" ] || [ "$mode" != 755 ]; then
            rm -rf "$work"
            error "Refusing to modify an existing foreign or non-contract Fedora font directory: $font_dir"
            return 1
        fi
    fi
    [ -d "$font_dir" ] || created_dir=1
    install -d -m 755 -o "$user" -g "$group" "$font_dir" || {
        rm -rf "$work"
        return 1
    }
    if [ "$created_dir" -eq 1 ]; then
        created_dir_identity=$(fedora_provider_directory_identity "$font_dir") || {
            rm -rf "$work"
            return 2
        }
        FEDORA_PROVIDER_CREATED_FONT_DIR_IDENTITY=$created_dir_identity
    fi
    status=0
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        destination="$font_dir/$(basename "$source")"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            cleanup_status=0
            fedora_font_provider_cleanup_installed || cleanup_status=2
            if [ "$created_dir" -eq 1 ]; then
                fedora_provider_remove_directory_if_unchanged \
                    "$font_dir" "$created_dir_identity" || cleanup_status=2
            fi
            rm -rf "$work"
            error "Refusing to overwrite an existing font file: $destination"
            return "$((cleanup_status == 0 ? 1 : 2))"
        fi
        staged=$(mktemp "$font_dir/.font.XXXXXX") || {
            status=1
            break
        }
        if ! install -m 644 -o "$user" -g "$group" "$source" "$staged"; then
            rm -f "$staged"
            status=1
            break
        fi
        staged_identity=$(fedora_provider_file_identity "$staged") || {
            rm -f "$staged"
            status=1
            break
        }
        # Recheck immediately before the atomic no-clobber link.  ln fails
        # rather than replacing a file created by a concurrent user.
        if [ -e "$destination" ] || [ -L "$destination" ] ||
            ! ln "$staged" "$destination"; then
            rm -f "$staged"
            status=1
            break
        fi
        rm -f -- "$staged"
        written_identity=$(fedora_provider_file_identity "$destination") || {
            status=1
            break
        }
        if [ "$written_identity" != "$staged_identity" ]; then
            error "Font destination changed during installation; preserving the concurrent file: $destination"
            status=2
            break
        fi
        installed_records+=("$destination|$written_identity")
        if [ -n "$FEDORA_PROVIDER_WRITTEN_FILES" ]; then
            FEDORA_PROVIDER_WRITTEN_FILES+=$'\n'
        fi
        FEDORA_PROVIDER_WRITTEN_FILES+="$destination|$written_identity"
    done < "$source_list"
    if [ "$status" -ne 0 ]; then
        cleanup_status=0
        fedora_font_provider_cleanup_installed || cleanup_status=2
        if [ "$created_dir" -eq 1 ]; then
            fedora_provider_remove_directory_if_unchanged \
                "$font_dir" "$created_dir_identity" || cleanup_status=2
        fi
        rm -rf "$work"
        return "$((cleanup_status == 0 ? 1 : 2))"
    fi
    if ! fedora_target_user_exec "$user" "$home" \
        fc-cache -f "$font_dir" >/dev/null 2>&1; then
        cleanup_status=0
        fedora_font_provider_cleanup_installed || cleanup_status=2
        if [ "$created_dir" -eq 1 ]; then
            fedora_provider_remove_directory_if_unchanged \
                "$font_dir" "$created_dir_identity" || cleanup_status=2
        fi
        rm -rf "$work"
        error "fc-cache failed for Fedora target-user font directory: $font_dir"
        return "$((cleanup_status == 0 ? 1 : 2))"
    fi
    rm -rf "$work"
    for target in "${needed[@]}"; do
        if fedora_font_target_satisfied "$target" "$user" "$home"; then
            continue
        else
            status=$?
        fi
        cleanup_status=0
        fedora_font_provider_cleanup_installed || cleanup_status=2
        if [ "$created_dir" -eq 1 ]; then
            fedora_provider_remove_directory_if_unchanged \
                "$font_dir" "$created_dir_identity" || cleanup_status=2
        fi
        error "Installed Fedora font provider failed its exact family/glyph contract: $target"
        [ "$cleanup_status" -eq 0 ] || return 2
        return "$status"
    done
    return 0
}

fedora_install_font_provider_targets() {
    platform_is_fedora || return 0
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}} status=0

    shift 2 || true
    require_writable_mode || return
    fedora_provider_architecture_satisfied || return
    fedora_provider_lock_acquire || return
    if _fedora_install_font_provider_targets_unlocked "$user" "$home" "$@";
    then
        status=0
    else
        status=$?
    fi
    fedora_provider_lock_release
    return "$status"
}

fedora_install_font_provider_target() {
    local target=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}

    fedora_install_font_provider_targets "$user" "$home" "$target"
}

_fedora_install_desktop_font_provider_unlocked() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}
    local target_list status=0
    local -a targets=()

    target_list=$(fedora_font_provider_targets "$home") || {
        status=$?
        return "$status"
    }
    mapfile -t targets <<< "$target_list"
    _fedora_install_font_provider_targets_unlocked "$user" "$home" "${targets[@]}"
}

fedora_install_desktop_font_provider() {
    platform_is_fedora || return 0
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}} status=0

    require_writable_mode || return
    fedora_provider_architecture_satisfied || return
    fedora_provider_lock_acquire || return
    if _fedora_install_desktop_font_provider_unlocked "$user" "$home";
    then
        status=0
    else
        status=$?
    fi
    fedora_provider_lock_release
    return "$status"
}

fedora_install_font_provider() {
    local target=${1:-} user home

    case "$target" in
        ttf-jetbrains-mono-nerd|ttf-jetbrains-maple-mono-nf-xx-xx|material-design-icons)
            user=${2:-${TARGET_USER:-}}
            home=${3:-${HOME_DIR:-}}
            fedora_install_font_provider_target "$target" "$user" "$home"
            ;;
        *)
            user=${1:-${TARGET_USER:-}}
            home=${2:-${HOME_DIR:-}}
            fedora_install_desktop_font_provider "$user" "$home"
            ;;
    esac
}

fedora_install_fonts() {
    fedora_install_desktop_font_provider "$@"
}
