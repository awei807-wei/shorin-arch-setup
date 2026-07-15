#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
HOME_DIR="$TEST_DIR/home"
TARGET_USER=tester
PARENT_DIR="$ROOT_DIR"
APPLICATION_DESKTOP_DIR="$TEST_DIR/applications"
GITHUB_PROVENANCE_DIR="$TEST_DIR/provenance"
SHORIN_ROOT="$ROOT_DIR"
SHORIN_READ_ONLY=0
export HOME_DIR TARGET_USER APPLICATION_DESKTOP_DIR GITHUB_PROVENANCE_DIR
export SHORIN_ROOT SHORIN_READ_ONLY

source "$ROOT_DIR/scripts/modules/applications/targets.sh"
source "$ROOT_DIR/scripts/modules/applications/config-apply.sh"
source "$ROOT_DIR/scripts/modules/applications/github-apps.sh"
source "$ROOT_DIR/scripts/modules/applications/privilege-apply.sh"

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

declare -A INSTALLED_PACKAGES=()
FLATPAK_STEAM_INSTALLED=0
FLATPAK_STEAM_LOCALE=0
GITHUB_REMOTE_OK=0
NIRI_CLIP_UNIT_ENABLED=0
LAZYVIM_CLONES=0
GITHUB_HEAD=0123456789abcdef0123456789abcdef01234567
GITHUB_CHECKOUT_DIRTY=0
AS_USER_LOG="$TEST_DIR/as-user.log"

state_package_present() {
    [ "${INSTALLED_PACKAGES[$1]:-0}" -eq 1 ]
}

state_flatpak_present() {
    [ "$1" = com.valvesoftware.Steam ] &&
        [ "$FLATPAK_STEAM_INSTALLED" -eq 1 ]
}

state_git_checkout() {
    [ "$GITHUB_REMOTE_OK" -eq 1 ] && [ "$3" = main ]
}

state_user_unit_enabled() {
    [ "$NIRI_CLIP_UNIT_ENABLED" -eq 1 ]
}

git() {
    if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] &&
        [ "${4:-}" = HEAD ]; then
        printf '%s\n' "$GITHUB_HEAD"
        return 0
    fi
    if [ "${1:-}" = -C ] && [ "${3:-}" = status ] &&
        [ "${4:-}" = --porcelain ]; then
        [ "$GITHUB_CHECKOUT_DIRTY" -eq 0 ] || printf ' M src/main.rs\n'
        return 0
    fi
    command git "$@"
}

flatpak() {
    case "$*" in
        'override --system --show com.valvesoftware.Steam')
            [ "$FLATPAK_STEAM_LOCALE" -eq 1 ] &&
                printf 'LANG=zh_CN.UTF-8\n'
            ;;
        'override --system --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam')
            FLATPAK_STEAM_LOCALE=1
            ;;
        *) return 1 ;;
    esac
}

as_user() {
    printf '%q ' "$@" >> "$AS_USER_LOG"
    printf '\n' >> "$AS_USER_LOG"
    if [ "${1:-}" = git ] && [ "${2:-}" = clone ]; then
        local destination=${4}
        LAZYVIM_CLONES=$((LAZYVIM_CLONES + 1))
        mkdir -p "$destination/lua/config" "$destination/.git"
        printf 'require("config.lazy")\n' > "$destination/init.lua"
        printf 'return {}\n' > "$destination/lua/config/lazy.lua"
        return 0
    fi
    if [[ " $* " == *' wineboot '* ]]; then
        mkdir -p "$HOME_DIR/.wine"
        return 0
    fi
    if [[ " $* " == *' wineserver '* ]]; then
        return 0
    fi
    if [[ " $* " == *' cargo build '* ]]; then
        local previous argument target_dir=""

        for argument in "$@"; do
            if [ "${previous:-}" = --target-dir ]; then
                target_dir=$argument
                break
            fi
            previous=$argument
        done
        [ -n "$target_dir" ] || return 1
        mkdir -p "$target_dir/release"
        printf '#!/usr/bin/env bash\n' > "$target_dir/release/focus-shift"
        chmod 755 "$target_dir/release/focus-shift"
        return 0
    fi
    "$@"
}

chown() {
    return 0
}

ensure_packages() {
    local package

    for package in "$@"; do
        INSTALLED_PACKAGES["$package"]=1
    done
}

write_github_provenance() {
    local app=$1 binary="$HOME_DIR/.local/bin/$1"
    local sha

    sha=$(sha256sum "$binary" | awk '{ print $1 }')
    mkdir -p "$GITHUB_PROVENANCE_DIR"
    printf 'app=%s\ncommit=%s\nsha256=%s\n' \
        "$app" "$GITHUB_HEAD" "$sha" > "$GITHUB_PROVENANCE_DIR/$app.build"
}

install_sudoers_file() {
    local source=$1 destination=$2

    install -D -m 440 "$source" "$destination"
}

mkdir -p "$HOME_DIR/.config/nvim/lua/config" "$APPLICATION_DESKTOP_DIR"
for package in "${LAZYVIM_PACKAGES[@]}" mpv steam; do
    INSTALLED_PACKAGES["$package"]=1
done
printf 'require("config.lazy")\n' > "$HOME_DIR/.config/nvim/init.lua"
printf 'return {}\n' > "$HOME_DIR/.config/nvim/lua/config/lazy.lua"
printf '[Desktop Entry]\nExec=mpv %%U\n\n[Desktop Action Edit]\nName=Edit\n' > \
    "$APPLICATION_DESKTOP_DIR/mpv.desktop"

application_entry_satisfied lazyvim || fail 'complete LazyVim must satisfy its target'
application_entry_satisfied mpv && fail 'missing NoDisplay must be application drift'
INSTALLED_PACKAGES[git]=0
converge_application_configs $'lazyvim\nmpv'
[ "$LAZYVIM_CLONES" -eq 0 ] ||
    fail 'unrelated or package drift must not reinstall complete LazyVim config'
INSTALLED_PACKAGES[git]=1
find "$HOME_DIR/.config" -maxdepth 1 -name 'nvim.old.apps.*' -print -quit |
    grep -q . && fail 'complete LazyVim must not be backed up'
application_entry_satisfied mpv || fail 'NoDisplay target must converge'
[ "$(awk '/^\[Desktop Entry\]$/{main=1;next} /^\[/{main=0} main && /^NoDisplay=true$/{count++} END{print count+0}' \
    "$APPLICATION_DESKTOP_DIR/mpv.desktop")" -eq 1 ] ||
    fail 'NoDisplay must be written inside the main Desktop Entry group'
! awk '/^\[Desktop Action Edit\]$/{action=1;next} /^\[/{action=0} action && /^NoDisplay=/{found=1} END{exit !found}' \
    "$APPLICATION_DESKTOP_DIR/mpv.desktop" ||
    fail 'NoDisplay must not be appended to a Desktop Action group'

for package in "${WINE_CONFIG_PACKAGES[@]}"; do
    INSTALLED_PACKAGES["$package"]=1
done
application_entry_satisfied wine &&
    fail 'Wine without its prefix must be configuration drift'
WINDOWS_FONT_SOURCE="$TEST_DIR/no-windows-fonts"
ensure_wine_config
grep -Fq "HOME=$HOME_DIR WINEPREFIX=$HOME_DIR/.wine" "$AS_USER_LOG" ||
    fail 'Wine user commands must receive explicit HOME and WINEPREFIX'
grep -Fq 'wineboot -u' "$AS_USER_LOG" ||
    fail 'Wine prefix convergence must invoke wineboot'
grep -Fq 'wineserver -w' "$AS_USER_LOG" ||
    fail 'Wine prefix convergence must wait for wineserver with the same environment'
WINDOWS_FONT_SOURCE="$ROOT_DIR/resources/windows-sim-fonts"
mkdir -p "$HOME_DIR/.wine/drive_c/windows/Fonts"
while IFS= read -r -d '' FONT; do
    cp "$FONT" "$HOME_DIR/.wine/drive_c/windows/Fonts/$(basename "$FONT")"
done < <(find "$WINDOWS_FONT_SOURCE" -maxdepth 1 -type f -print0)
application_entry_satisfied wine || fail 'complete Wine configuration must pass'

for package in "${LUTRIS_CONFIG_PACKAGES[@]}"; do
    INSTALLED_PACKAGES["$package"]=1
done
INSTALLED_PACKAGES[lutris]=1
application_entry_satisfied lutris ||
    fail 'declared Lutris dependencies must be part of its target'
INSTALLED_PACKAGES[lib32-openal]=0
application_entry_satisfied lutris &&
    fail 'missing Lutris runtime dependencies must be drift'
INSTALLED_PACKAGES[lib32-openal]=1

INSTALLED_PACKAGES[firefox]=1
application_entry_satisfied firefox &&
    fail 'missing first-run Firefox defaults must be drift'
while IFS= read -r -d '' FIREFOX_SOURCE; do
    FIREFOX_RELATIVE=${FIREFOX_SOURCE#"$FIREFOX_DEFAULT_SOURCE"/}
    mkdir -p "$HOME_DIR/.mozilla/$(dirname "$FIREFOX_RELATIVE")"
    cp "$FIREFOX_SOURCE" "$HOME_DIR/.mozilla/$FIREFOX_RELATIVE"
done < <(find "$FIREFOX_DEFAULT_SOURCE" -type f -print0)
application_entry_satisfied firefox ||
    fail 'deployed Firefox defaults must satisfy the target'

printf '[Desktop Entry]\nExec=/usr/bin/steam %%U\n' > \
    "$APPLICATION_DESKTOP_DIR/steam.desktop"
application_entry_satisfied steam && fail 'unpatched native Steam must be drift'
converge_application_configs steam
application_entry_satisfied steam || fail 'native Steam locale must converge'
STEAM_COPY="$TEST_DIR/steam.desktop.copy"
cp "$APPLICATION_DESKTOP_DIR/steam.desktop" "$STEAM_COPY"
converge_application_configs steam
cmp -s "$STEAM_COPY" "$APPLICATION_DESKTOP_DIR/steam.desktop" ||
    fail 'native Steam locale convergence must be idempotent'

FLATPAK_STEAM_INSTALLED=1
application_entry_satisfied flatpak:com.valvesoftware.Steam &&
    fail 'Flatpak Steam without locale override must be drift'
converge_application_configs flatpak:com.valvesoftware.Steam
application_entry_satisfied flatpak:com.valvesoftware.Steam ||
    fail 'Flatpak Steam locale override must converge'

printf '[Desktop Entry]\nExec=/usr/bin/steam %%U\n' > \
    "$APPLICATION_DESKTOP_DIR/steam.desktop"
FLATPAK_STEAM_LOCALE=0
converge_application_configs mpv
grep -Fq 'Exec=/usr/bin/steam %U' "$APPLICATION_DESKTOP_DIR/steam.desktop" ||
    fail 'an undeclared Steam target must not be modified'
[ "$FLATPAK_STEAM_LOCALE" -eq 0 ] ||
    fail 'an undeclared Flatpak Steam target must not receive an override'

mkdir -p "$HOME_DIR/.local/src/focus-shift/.git" "$HOME_DIR/.local/bin"
GITHUB_REMOTE_OK=1
application_entry_satisfied GitHub:focus-shift &&
    fail 'GitHub target without build provenance must be drift'
_build_and_install_cargo_binary \
    "$HOME_DIR/.local/src/focus-shift" focus-shift ||
    fail 'GitHub build must atomically install a binary and its provenance'
application_entry_satisfied GitHub:focus-shift ||
    fail 'GitHub target must accept matching checkout, binary and provenance'
GITHUB_CHECKOUT_DIRTY=1
application_entry_satisfied GitHub:focus-shift &&
    fail 'GitHub target must reject provenance for a modified checkout'
GITHUB_CHECKOUT_DIRTY=0
printf '# tampered\n' >> "$HOME_DIR/.local/bin/focus-shift"
application_entry_satisfied GitHub:focus-shift &&
    fail 'GitHub target must reject a binary that differs from provenance'
printf '#!/usr/bin/env bash\n' > "$HOME_DIR/.local/bin/focus-shift"
chmod 755 "$HOME_DIR/.local/bin/focus-shift"
write_github_provenance focus-shift
GITHUB_HEAD=1111111111111111111111111111111111111111
application_entry_satisfied GitHub:focus-shift &&
    fail 'GitHub target must reject provenance from an older checkout HEAD'
GITHUB_HEAD=0123456789abcdef0123456789abcdef01234567
GITHUB_REMOTE_OK=0
application_entry_satisfied GitHub:focus-shift &&
    fail 'GitHub target must reject a checkout with the wrong remote'

mkdir -p "$HOME_DIR/.local/src/niri-clip/.git" \
    "$HOME_DIR/.local/src/niri-clip/systemd" \
    "$HOME_DIR/.config/systemd/user"
printf '#!/usr/bin/env bash\n' > "$HOME_DIR/.local/bin/niri-clip"
chmod 755 "$HOME_DIR/.local/bin/niri-clip"
write_github_provenance niri-clip
printf '[Service]\nExecStart=niri-clip\n' > \
    "$HOME_DIR/.local/src/niri-clip/systemd/niri-clip.service"
cp "$HOME_DIR/.local/src/niri-clip/systemd/niri-clip.service" \
    "$HOME_DIR/.config/systemd/user/niri-clip.service"
GITHUB_REMOTE_OK=1
application_entry_satisfied GitHub:niri-clip &&
    fail 'niri-clip without its wants link must be drift'
NIRI_CLIP_UNIT_ENABLED=1
application_entry_satisfied GitHub:niri-clip ||
    fail 'niri-clip source, binary, service and wants link must satisfy target'

APPLICATIONS_TEMP_SUDOERS_FILE="$TEST_DIR/sudoers/temporary-applications"
begin_temporary_aur_sudoers
[ ! -e "$APPLICATIONS_TEMP_SUDOERS_FILE" ] ||
    fail 'repository-only targets must not create temporary NOPASSWD'
begin_temporary_aur_sudoers vicinae-bin
grep -Fqx "$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pacman" \
    "$APPLICATIONS_TEMP_SUDOERS_FILE" ||
    fail 'AUR targets must receive the temporary package-install privilege'
end_temporary_aur_sudoers
[ ! -e "$APPLICATIONS_TEMP_SUDOERS_FILE" ] ||
    fail 'temporary AUR privilege must be revoked immediately after use'

printf 'PASS: applications configuration contract\n'
