#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Shared desired-state, atomic deployment, and verification primitives.

ensure_package() {
    local package=$1
    pacman -Q "$package" >/dev/null 2>&1 ||
        pacman -S --noconfirm --needed "$package"
    pacman -Q "$package" >/dev/null 2>&1
}

ensure_packages() {
    local package
    for package in "$@"; do
        ensure_package "$package"
    done
}

ensure_aur_package() {
    local package=$1
    local user=${2:-${TARGET_USER:-}}

    [ -n "$user" ] || { error "TARGET_USER is required for AUR package $package"; return 1; }
    pacman -Q "$package" >/dev/null 2>&1 ||
        runuser -u "$user" -- yay -S --noconfirm --needed \
            --answerdiff=None --answerclean=None "$package"
    pacman -Q "$package" >/dev/null 2>&1
}

ensure_flatpak() {
    local app=$1
    flatpak info --system "$app" >/dev/null 2>&1 ||
        flatpak install --system -y flathub "$app"
    flatpak info --system "$app" >/dev/null 2>&1
}

ensure_service_enabled() {
    local unit=$1
    systemctl is-enabled --quiet "$unit" || systemctl enable "$unit"
    systemctl is-enabled --quiet "$unit"
}

ensure_service_started() {
    local unit=$1
    ensure_service_enabled "$unit"
    systemctl is-active --quiet "$unit" || systemctl start "$unit"
    systemctl is-active --quiet "$unit"
}

ensure_line() {
    local file=$1 line=$2
    mkdir -p "$(dirname "$file")"
    touch "$file"
    grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

install_if_changed() {
    local source=$1 destination=$2 mode=$3

    if [ -f "$destination" ] && cmp -s "$source" "$destination"; then
        return 0
    fi

    if ! install -D -m "$mode" "$source" "${destination}.new"; then
        rm -f "${destination}.new"
        return 1
    fi
    if ! mv -f "${destination}.new" "$destination"; then
        rm -f "${destination}.new"
        return 1
    fi
}

install_user_file_once() {
    local source=$1 destination=$2 mode=$3 user=$4

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        return 0
    fi
    install -D -m "$mode" -o "$user" -g "$user" "$source" "$destination"
}

deploy_user_tree_once() {
    local source_root=$1 destination_root=$2 user=$3
    local source relative destination mode

    while IFS= read -r -d '' source; do
        relative=${source#"$source_root"/}
        destination="$destination_root/$relative"
        if [ -d "$source" ]; then
            install -d -o "$user" -g "$user" "$destination"
        elif [ -L "$source" ]; then
            if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
                install -d -o "$user" -g "$user" "$(dirname "$destination")"
                runuser -u "$user" -- ln -s "$(readlink "$source")" "$destination"
            fi
        elif [ -f "$source" ]; then
            mode=$(stat -c '%a' "$source")
            install_user_file_once "$source" "$destination" "$mode" "$user"
        fi
    done < <(find "$source_root" -mindepth 1 -print0)
}

ensure_git_checkout() {
    local user=$1 repository=$2 branch=$3 destination=$4
    local actual

    if [ -d "$destination/.git" ]; then
        actual=$(runuser -u "$user" -- git -C "$destination" remote get-url origin)
        [ "$actual" = "$repository" ] || {
            error "Refusing to update $destination: origin is $actual"
            return 1
        }
        runuser -u "$user" -- git -C "$destination" fetch origin "$branch"
        runuser -u "$user" -- git -C "$destination" checkout "$branch"
        runuser -u "$user" -- git -C "$destination" merge --ff-only "origin/$branch"
        return 0
    fi

    local parent staged
    parent=$(dirname "$destination")
    staged=$(mktemp -d "$parent/.checkout.XXXXXX")
    rmdir "$staged"
    if ! runuser -u "$user" -- git clone --branch "$branch" --single-branch \
        "$repository" "$staged"; then
        [ ! -e "$staged" ] || find "$staged" -depth -delete
        return 1
    fi
    mv "$staged" "$destination"
}

ensure_key_value() {
    local file=$1 key=$2 value=$3
    local mode=${4:-644}
    local tmp

    tmp=$(mktemp "${file}.XXXXXX")
    if [ -f "$file" ]; then
        awk -v key="$key" '
            $0 !~ "^[[:space:]#]*" key "[[:space:]]*=" { print }
        ' "$file" > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    if ! install_if_changed "$tmp" "$file" "$mode"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

ensure_pacman_section() {
    local file=$1 section=$2 body=$3
    local tmp

    tmp=$(mktemp "${file}.XXXXXX")
    awk -v wanted="$section" '
        /^\[[^]]+\]$/ {
            current=$0
            gsub(/^\[|\]$/, "", current)
            skip=(current == wanted)
        }
        !skip { print }
    ' "$file" > "$tmp"
    printf '\n[%s]\n%s\n' "$section" "$body" >> "$tmp"
    if ! pacman-conf --config "$tmp" >/dev/null ||
        ! install_if_changed "$tmp" "$file" 644; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

install_sudoers_file() {
    local source=$1 destination=$2

    visudo -cf "$source" >/dev/null
    install_if_changed "$source" "$destination" 440
    visudo -cf "$destination" >/dev/null
}

ensure_fstab_entry() {
    local source=$1 target=$2 fstype=$3 options=$4
    local dump=${5:-0} pass=${6:-0}
    local fstab_file=${FSTAB_FILE:-/etc/fstab}
    local tmp

    tmp=$(mktemp "${fstab_file}.XXXXXX")
    awk -v src="$source" -v dst="$target" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 != src && $2 != dst { print }
    ' "$fstab_file" > "$tmp"
    printf '%s %s %s %s %s %s\n' \
        "$source" "$target" "$fstype" "$options" "$dump" "$pass" >> "$tmp"
    if ! findmnt --verify --tab-file "$tmp" ||
        ! install_if_changed "$tmp" "$fstab_file" 644; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

ensure_user_unit_enabled() {
    local user=$1 unit=$2 target=${3:-default.target}
    local home uid unit_dir wants_dir runtime_dir

    home=$(getent passwd "$user" | cut -d: -f6)
    uid=$(id -u "$user")
    unit_dir="$home/.config/systemd/user"
    wants_dir="$unit_dir/${target}.wants"
    runtime_dir="/run/user/$uid"

    install -d -o "$user" -g "$user" "$wants_dir"
    runuser -u "$user" -- ln -sfn "../$unit" "$wants_dir/$unit"

    if [ -S "$runtime_dir/bus" ]; then
        runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            systemctl --user daemon-reload
        runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            systemctl --user start "$unit"
    else
        log "$unit enabled for $user; start is pending until the next login."
        USER_UNIT_PENDING+=("$user:$unit")
    fi
}

verify_package() {
    pacman -Q "$1" >/dev/null 2>&1
}

verify_flatpak() {
    flatpak info --system "$1" >/dev/null 2>&1
}

verify_service() {
    systemctl is-enabled --quiet "$1"
}

verify_file() {
    [ -s "$1" ]
}

verify_user_unit() {
    local user=$1 unit=$2 target=${3:-default.target}
    local home
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -L "$home/.config/systemd/user/${target}.wants/$unit" ]
}

USER_UNIT_PENDING=()
