#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora exact-family font contracts.

fedora_font_source_contract_valid() {
    local target=$1 version url digest expected_version expected_url expected_digest
    local size='' expected_size='' ttf_count='' expected_ttf_count=''

    case "$target" in
        ttf-jetbrains-mono-nerd)
            version=$FEDORA_JETBRAINSMONO_NERD_VERSION
            url=$FEDORA_JETBRAINSMONO_NERD_URL
            digest=$FEDORA_JETBRAINSMONO_NERD_SHA256
            expected_version=$FEDORA_JETBRAINSMONO_NERD_VERSION_PINNED
            expected_url=$FEDORA_JETBRAINSMONO_NERD_URL_PINNED
            expected_digest=$FEDORA_JETBRAINSMONO_NERD_SHA256_PINNED
            ;;
        ttf-jetbrains-maple-mono-nf-xx-xx)
            version=$FEDORA_JETBRAINS_MAPLE_VERSION
            url=$FEDORA_JETBRAINS_MAPLE_URL
            digest=$FEDORA_JETBRAINS_MAPLE_SHA256
            expected_version=$FEDORA_JETBRAINS_MAPLE_VERSION_PINNED
            expected_url=$FEDORA_JETBRAINS_MAPLE_URL_PINNED
            expected_digest=$FEDORA_JETBRAINS_MAPLE_SHA256_PINNED
            size=$FEDORA_JETBRAINS_MAPLE_SIZE
            expected_size=$FEDORA_JETBRAINS_MAPLE_SIZE_PINNED
            ttf_count=$FEDORA_JETBRAINS_MAPLE_TTF_COUNT
            expected_ttf_count=$FEDORA_JETBRAINS_MAPLE_TTF_COUNT_PINNED
            ;;
        material-design-icons)
            version=$FEDORA_MATERIAL_DESIGN_ICONS_VERSION
            url=$FEDORA_MATERIAL_DESIGN_ICONS_URL
            digest=$FEDORA_MATERIAL_DESIGN_ICONS_SHA256
            expected_version=$FEDORA_MATERIAL_DESIGN_ICONS_VERSION_PINNED
            expected_url=$FEDORA_MATERIAL_DESIGN_ICONS_URL_PINNED
            expected_digest=$FEDORA_MATERIAL_DESIGN_ICONS_SHA256_PINNED
            ;;
        *) return 1 ;;
    esac
    [ "$version" = "$expected_version" ] || {
        error "Unpinned version for Fedora font target: $target"
        return 1
    }
    [ "$url" = "$expected_url" ] || {
        error "Unpinned source URL for Fedora font target: $target"
        return 1
    }
    [ "$digest" = "$expected_digest" ] || {
        error "Unpinned SHA-256 for Fedora font target: $target"
        return 1
    }
    [ -z "$expected_size" ] || [ "$size" = "$expected_size" ] || {
        error "Unpinned byte size for Fedora font target: $target"
        return 1
    }
    [ -z "$expected_ttf_count" ] ||
        [ "$ttf_count" = "$expected_ttf_count" ] || {
            error "Unpinned TTF count for Fedora font target: $target"
            return 1
        }
}

fedora_target_user_provider_prerequisites_satisfied() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}} command_name

    for command_name in curl sha256sum stat unzip xz tar flock fc-cache fc-match fc-query fc-scan; do
        fedora_target_user_command_path "$user" "$home" "$command_name" \
            >/dev/null || return $?
    done
}

fedora_kitty_config_path() {
    local home=${1:-${HOME_DIR:-}}

    [ -n "$home" ] || return 1
    printf '%s\n' "${FEDORA_KITTY_CONFIG_FILE:-$home/.config/kitty/kitty.conf}"
}

fedora_kitty_maple_font_required() {
    local home=${1:-${HOME_DIR:-}} config

    config=$(fedora_kitty_config_path "$home") || return 1
    [ -e "$config" ] || return 1
    [ -r "$config" ] || return 2
    awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/[[:space:]]+#.*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "font_family JetBrains Maple Mono") found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$config"
}

fedora_font_provider_targets() {
    local home=${1:-${HOME_DIR:-}} maple_status=0

    printf '%s\n' ttf-jetbrains-mono-nerd
    if fedora_kitty_maple_font_required "$home"; then
        printf '%s\n' ttf-jetbrains-maple-mono-nf-xx-xx
    else
        maple_status=$?
        [ "$maple_status" -eq 1 ] || return "$maple_status"
    fi
    printf '%s\n' material-design-icons
}

fedora_font_family_from_target() {
    case "$1" in
        ttf-jetbrains-mono-nerd) printf '%s\n' "$FEDORA_NERD_FONT_FAMILY" ;;
        ttf-jetbrains-maple-mono-nf-xx-xx) printf '%s\n' "$FEDORA_MAPLE_FONT_FAMILY" ;;
        material-design-icons) printf '%s\n' "$FEDORA_MDI_FONT_FAMILY" ;;
        *) return 1 ;;
    esac
}

fedora_font_glyphs_from_target() {
    case "$1" in
        material-design-icons) printf '%s\n' "$FEDORA_MDI_GLYPHS" ;;
        *) return 0 ;;
    esac
}

fedora_font_charset_contains() {
    local charset=$1 wanted=$2 token start end value start_value end_value

    wanted=${wanted#U+}
    wanted=${wanted#u+}
    [[ "$wanted" =~ ^[[:xdigit:]]+$ ]] || return 1
    charset=${charset//,/ }
    for token in $charset; do
        [ -n "$token" ] || continue
        if [[ "$token" =~ ^([[:xdigit:]]+)-([[:xdigit:]]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
        elif [[ "$token" =~ ^[[:xdigit:]]+$ ]]; then
            start=$token
            end=$token
        else
            continue
        fi
        value=$((16#$wanted))
        start_value=$((16#$start))
        end_value=$((16#$end))
        if [ "$value" -ge "$start_value" ] && [ "$value" -le "$end_value" ]; then
            return 0
        fi
    done
    return 1
}

fedora_font_family_list_contains() {
    local family=$1 family_list=$2

    awk -v expected="$family" -F, '
        {
            for (i = 1; i <= NF; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
                if ($i == expected) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$family_list"
}

fedora_font_family_contract_from_file() {
    local family=$1 font_file=$2 user=$3 home=$4 query_family scan_family

    query_family=$(fedora_target_user_exec "$user" "$home" \
        fc-query -f '%{family}\n' "$font_file" 2>/dev/null) || return $?
    scan_family=$(fedora_target_user_exec "$user" "$home" \
        fc-scan -f '%{family}\n' "$font_file" 2>/dev/null) || return $?
    fedora_font_family_list_contains "$family" "$query_family" || return 1
    fedora_font_family_list_contains "$family" "$scan_family"
}

fedora_font_family_satisfied() {
    local family=$1 glyphs=${2:-} user=$3 home=$4
    local matched_file matched_family glyph
    local query_charset scan_charset

    matched_family=$(fedora_target_user_exec "$user" "$home" \
        fc-match -f '%{family}\n' "$family" 2>/dev/null) || return $?
    fedora_font_family_list_contains "$family" "$matched_family" || return 1
    matched_file=$(fedora_target_user_exec "$user" "$home" \
        fc-match -f '%{file}\n' "$family" 2>/dev/null) || return $?
    [ -f "$matched_file" ] && [ ! -L "$matched_file" ] || return 1
    case "$matched_file" in
        "$home/.local/share/fonts/$FEDORA_SHORIN_FONT_DIR_NAME"/*)
            fedora_target_user_provider_file_contract "$matched_file" \
                "$user" "$home" 644 || return
            ;;
    esac
    fedora_font_family_contract_from_file "$family" "$matched_file" \
        "$user" "$home" || return
    [ -n "$glyphs" ] || return 0
    query_charset=$(fedora_target_user_exec "$user" "$home" \
        fc-query -f '%{charset}\n' "$matched_file" 2>/dev/null) || return $?
    scan_charset=$(fedora_target_user_exec "$user" "$home" \
        fc-scan -f '%{charset}\n' "$matched_file" 2>/dev/null) || return $?
    for glyph in $glyphs; do
        fedora_font_charset_contains "$query_charset" "$glyph" || return 1
        fedora_font_charset_contains "$scan_charset" "$glyph" || return 1
    done
}

fedora_font_target_satisfied() {
    local target=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local family glyphs

    [ -n "$user" ] && [ -n "$home" ] || return 2
    family=$(fedora_font_family_from_target "$target") || return 1
    glyphs=$(fedora_font_glyphs_from_target "$target") || return 1
    fedora_font_family_satisfied "$family" "$glyphs" "$user" "$home"
}

fedora_desktop_font_provider_satisfied() {
    local target

    platform_is_fedora || return 0
    while IFS= read -r target; do
        fedora_font_target_satisfied "$target" "${TARGET_USER:-}" \
            "${HOME_DIR:-}" || return
    done < <(fedora_font_provider_targets "${HOME_DIR:-}")
}

fedora_font_provider_satisfied() {
    case "${1:-}" in
        ttf-jetbrains-mono-nerd|ttf-jetbrains-maple-mono-nf-xx-xx|material-design-icons)
            fedora_font_target_satisfied "$1" "${2:-${TARGET_USER:-}}" \
                "${3:-${HOME_DIR:-}}"
            ;;
        *) fedora_desktop_font_provider_satisfied ;;
    esac
}
