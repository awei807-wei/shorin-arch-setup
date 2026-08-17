#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/desktop-niri/targets.sh"

disable_matugen_starship_output() {
    local temporary mode

    if ! niri_matugen_starship_output_disabled; then
        temporary=$(mktemp)
        awk '
            /^[[:space:]]*\[templates[.]starship\][[:space:]]*(#.*)?$/ {
                skip=1
                next
            }
            skip && /^[[:space:]]*\[[^]]+\][[:space:]]*(#.*)?$/ { skip=0 }
            !skip { print }
        ' "$NIRI_MATUGEN_CONFIG_FILE" > "$temporary"
        mode=$(stat -c '%a' "$NIRI_MATUGEN_CONFIG_FILE")
        install_if_changed "$temporary" "$NIRI_MATUGEN_CONFIG_FILE" "$mode"
        rm -f "$temporary"
        chown "$TARGET_USER:" "$NIRI_MATUGEN_CONFIG_FILE"
    fi
    rm -f "$NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE"
    niri_matugen_starship_output_disabled &&
        niri_matugen_starship_template_absent
}

dotfiles_checkout_is_safe() {
    local user=$1 repository=$2 destination=$3 home=$4 actual

    [ -d "$destination/.git" ] || return 1
    [ ! -L "$destination" ] || return 1
    [ "$(stat -c '%U' "$destination")" = "$user" ] || return 1
    actual=$(runuser -u "$user" -- env HOME="$home" \
        git -C "$destination" remote get-url origin) || return 1
    [ "${actual%/}" = "${repository%/}" ] || return 1
    [ -z "$(runuser -u "$user" -- env HOME="$home" \
        git -C "$destination" status --porcelain)" ]
}

dotfiles_checkout_is_current() {
    local user=$1 repository=$2 branch=$3 destination=$4 home=$5
    local actual_branch actual_commit remote_commit

    dotfiles_checkout_is_safe "$user" "$repository" "$destination" "$home" ||
        return 1
    actual_branch=$(runuser -u "$user" -- env HOME="$home" \
        git -C "$destination" branch --show-current) || return 1
    [ "$actual_branch" = "$branch" ] || return 1
    actual_commit=$(runuser -u "$user" -- env HOME="$home" \
        git -C "$destination" rev-parse HEAD) || return 1
    remote_commit=$(runuser -u "$user" -- env HOME="$home" \
        git -C "$destination" rev-parse "origin/$branch") || return 1
    [ "$actual_commit" = "$remote_commit" ]
}

dotfiles_source_contract() {
    local checkout=$1
    local dotfiles="$checkout/dotfiles"
    local config_dir="$dotfiles/.config"
    local niri_dir="$config_dir/niri"
    local quickshell_dir="$config_dir/quickshell"
    local quickshell_scripts_dir="$quickshell_dir/scripts"
    local lockscreen_script="$quickshell_scripts_dir/lockscreen.sh"
    local wallpapers="$checkout/wallpapers"
    local wallpaper="$wallpapers/$(basename "$NIRI_DEFAULT_WALLPAPER_FILE")"
    local starship="$config_dir/starship.toml"
    local script

    [ -d "$dotfiles" ] && [ ! -L "$dotfiles" ] || return 1
    [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || return 1
    [ -d "$niri_dir" ] && [ ! -L "$niri_dir" ] || return 1
    [ -d "$quickshell_dir" ] && [ ! -L "$quickshell_dir" ] || return 1
    [ -d "$quickshell_scripts_dir" ] && [ ! -L "$quickshell_scripts_dir" ] || return 1
    [ -d "$wallpapers" ] && [ ! -L "$wallpapers" ] || return 1
    [ -f "$niri_dir/config.kdl" ] && [ -s "$niri_dir/config.kdl" ] &&
        [ ! -L "$niri_dir/config.kdl" ] || return 1
    [ -f "$lockscreen_script" ] && [ -s "$lockscreen_script" ] &&
        [ ! -L "$lockscreen_script" ] && [ -x "$lockscreen_script" ] || return 1
    niri_quickshell_tree_contract "$quickshell_dir" || return 1
    [ -f "$wallpaper" ] && [ -s "$wallpaper" ] && [ ! -L "$wallpaper" ] ||
        return 1
    [ -f "$starship" ] && [ -s "$starship" ] && [ ! -L "$starship" ] ||
        return 1
    for script in \
        "$config_dir/scripts/matugen-select-type.sh" \
        "$config_dir/scripts/niri_set_overview_blur_dark_bg.sh" \
        "$config_dir/scripts/niri_auto_blur_bg.sh" \
        "$config_dir/matugen/config.toml"; do
        [ -f "$script" ] && [ -s "$script" ] && [ ! -L "$script" ] ||
            return 1
    done
}

# The generic tree pass intentionally keeps existing files untouched.  The
# QuickShell tree is the exception: it must be staged, validated, backed up,
# and atomically replaced by niri_quickshell_stage_and_deploy.  Keep the
# generic restore pass from ever traversing that subtree.
deploy_user_tree_without_quickshell() {
    require_writable_mode || return
    local source_root=$1 destination_root=$2 user=$3
    local group=${4:-$user}
    local source relative destination mode

    while IFS= read -r -d '' source; do
        relative=${source#"$source_root"/}
        case "$relative" in
            .config/quickshell|.config/quickshell/*) continue ;;
        esac
        destination="$destination_root/$relative"
        if [ -d "$source" ]; then
            install -d -o "$user" -g "$group" "$destination" || return
        elif [ -L "$source" ]; then
            if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
                install -d -o "$user" -g "$group" "$(dirname "$destination")" ||
                    return
                niri_run_as_user "$user" ln -s "$(readlink "$source")" \
                    "$destination" || return
            fi
        elif [ -f "$source" ]; then
            mode=$(stat -c '%a' "$source")
            install_user_file_once "$source" "$destination" "$mode" \
                "$user" "$group" || return
        fi
    done < <(find "$source_root" -mindepth 1 -print0)
}

ensure_dotfiles_checkout() {
    local user=$1 home=$2
    local github=${NIRI_DOTFILES_GITHUB_URL:-https://github.com/awei807-wei/ShorinArchExperience-ArchlinuxGuide.git}
    local gitee=${NIRI_DOTFILES_GITEE_URL:-https://gitee.com/shorinkiwata/ShorinArchExperience-ArchlinuxGuide.git}
    local checkout=${NIRI_DOTFILES_CHECKOUT:-/tmp/shorin-repo}
    local fallback_checkout=${NIRI_DOTFILES_FALLBACK_CHECKOUT:-${checkout}.gitee}

    if ensure_git_checkout "$user" "$github" main "$checkout" "$home" >/dev/null &&
        dotfiles_checkout_is_current "$user" "$github" main "$checkout" "$home" &&
        dotfiles_source_contract "$checkout"; then
        printf '%s\n' "$checkout"
        return 0
    fi
    if { [ -e "$checkout" ] || [ -L "$checkout" ]; } &&
        ! dotfiles_checkout_is_safe "$user" "$github" "$checkout" "$home"; then
        die "Refusing an untrusted or modified dotfiles checkout: $checkout"
        return 1
    fi

    if ensure_git_checkout "$user" "$gitee" main "$fallback_checkout" "$home" >/dev/null &&
        dotfiles_checkout_is_current "$user" "$gitee" main "$fallback_checkout" "$home" &&
        dotfiles_source_contract "$fallback_checkout"; then
        printf '%s\n' "$fallback_checkout"
        return 0
    fi
    if { [ -e "$fallback_checkout" ] || [ -L "$fallback_checkout" ]; } &&
        ! dotfiles_checkout_is_safe "$user" "$gitee" "$fallback_checkout" "$home"; then
        die "Refusing an untrusted or modified Gitee dotfiles checkout: $fallback_checkout"
        return 1
    fi
    die 'Unable to update ShorinArchExperience-ArchlinuxGuide from GitHub or Gitee.'
    return 1
}

deploy_dotfiles() {
    local checkout=$1 source_file destination temporary mode status=0 relative

    niri_desktop_txn_begin || return 1
    if ! dotfiles_source_contract "$checkout"; then
        error "Dotfiles source contract failed: $checkout"
        niri_desktop_txn_finish 1
        return 1
    fi
    if [ ! -d "$checkout/dotfiles" ]; then
        error 'Verified checkout has no dotfiles.'
        niri_desktop_txn_finish 1
        return 1
    fi

    # Snapshot every destination that the source tree can touch, excluding
    # QuickShell.  QuickShell is snapshotted as one unit and deployed by its
    # own staging transaction below.
    while IFS= read -r -d '' source_file; do
        relative=${source_file#"$checkout/dotfiles"/}
        case "$relative" in
            .config/quickshell|.config/quickshell/*) continue ;;
        esac
        niri_desktop_txn_snapshot "$HOME_DIR/$relative" || status=1
    done < <(find "$checkout/dotfiles" -mindepth 1 -print0)
    niri_desktop_txn_snapshot "$NIRI_QUICKSHELL_DIR" || status=1
    # The state directory contains both the source digest and QuickShell
    # backups.  Snapshot it as one unit so a failure cannot leave a newly
    # created state directory or a partial backup behind.
    niri_desktop_txn_snapshot "$NIRI_DESKTOP_STATE_DIR" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_CONFIG_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_GUARD_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_RUSTUP_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_LOCAL_ENV_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_WALLPAPER_DIR" || status=1
    niri_desktop_txn_snapshot "$NIRI_TEMPLATES_DIR" || status=1
    if [ "$status" -ne 0 ]; then
        niri_desktop_txn_finish 1
        return 1
    fi

    if [ "$TARGET_USER" != shorin ]; then
        source_file="$checkout/dotfiles/.config/gtk-3.0/bookmarks"
        if [ -f "$source_file" ]; then
            temporary=$(mktemp)
            if ! sed "s/shorin/$TARGET_USER/g" "$source_file" > "$temporary" ||
                ! install_user_file_once "$temporary" \
                    "$HOME_DIR/.config/gtk-3.0/bookmarks" 644 "$TARGET_USER"; then
                rm -f "$temporary"
                niri_desktop_txn_finish 1
                return 1
            fi
            rm -f "$temporary"
        fi
    fi

    source_file="$checkout/dotfiles/.config/niri/config.kdl"
    if [ -f "$source_file" ]; then
        temporary=$(mktemp)
        if ! sed 's/\& \/usr\/lib\/xdg-desktop-portal-gnome//' \
            "$source_file" > "$temporary" ||
            ! install_user_file_once "$temporary" \
                "$HOME_DIR/.config/niri/config.kdl" 644 "$TARGET_USER"; then
            rm -f "$temporary"
            niri_desktop_txn_finish 1
            return 1
        fi
        rm -f "$temporary"
    fi
    if ! deploy_user_tree_without_quickshell "$checkout/dotfiles" \
        "$HOME_DIR" "$TARGET_USER"; then
        niri_desktop_txn_finish 1
        return 1
    fi
    if ! niri_quickshell_stage_and_deploy "$checkout" "$TARGET_USER"; then
        error 'Unable to atomically converge the QuickShell tree.'
        niri_desktop_txn_finish 1
        return 1
    fi
    for source_file in \
        "$checkout/dotfiles/.config/scripts/matugen-select-type.sh" \
        "$checkout/dotfiles/.config/scripts/niri_set_overview_blur_dark_bg.sh" \
        "$checkout/dotfiles/.config/scripts/niri_auto_blur_bg.sh" \
        "$checkout/dotfiles/.config/matugen/config.toml"; do
        [ -f "$source_file" ] || continue
        destination="$HOME_DIR/${source_file#"$checkout/dotfiles"}"
        if ! niri_deploy_wallpaper_compat_file "$source_file" "$destination" \
            "$TARGET_USER"; then
            niri_desktop_txn_finish 1
            return 1
        fi
    done
    source_file="$checkout/dotfiles/.config/starship.toml"
    if ! [ -f "$source_file" ] || ! [ -s "$source_file" ] ||
        [ -L "$source_file" ]; then
        error 'Verified checkout has no regular Starship configuration.'
        niri_desktop_txn_finish 1
        return 1
    fi
    if [ "$(stat -c '%U' "$source_file")" != "$TARGET_USER" ]; then
        error 'Verified checkout has an incorrectly owned Starship configuration.'
        niri_desktop_txn_finish 1
        return 1
    fi
    if ! disable_matugen_starship_output; then
        niri_desktop_txn_finish 1
        return 1
    fi
    mode=$(stat -c '%a' "$source_file")
    if ! install_if_changed "$source_file" "$NIRI_STARSHIP_CONFIG_FILE" "$mode" ||
        ! chown "$TARGET_USER:" "$NIRI_STARSHIP_CONFIG_FILE" ||
        ! niri_starship_config_deployed; then
        niri_desktop_txn_finish 1
        return 1
    fi
    if ! ensure_niri_fish_sources "$TARGET_USER" ||
        ! ensure_niri_fish_config "$TARGET_USER"; then
        niri_desktop_txn_finish 1
        return 1
    fi
    if ! deploy_wallpapers_and_templates "$checkout"; then
        niri_desktop_txn_finish 1
        return 1
    fi
    niri_desktop_txn_finish 0
}

configure_desktop_theme() {
    local gtk4="$HOME_DIR/.config/gtk-4.0"
    local theme="$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0"
    local portal_dir="$HOME_DIR/.config/xdg-desktop-portal"
    local temporary

    as_user rm -f "$gtk4/gtk.css" "$gtk4/gtk-dark.css"
    as_user ln -sfn "$theme/gtk-dark.css" "$gtk4/gtk-dark.css"
    as_user ln -sfn "$theme/gtk.css" "$gtk4/gtk.css"

    if command -v flatpak >/dev/null 2>&1; then
        as_user flatpak override --user --filesystem="$HOME_DIR/.themes"
        as_user flatpak override --user --filesystem=xdg-config/gtk-4.0
        as_user flatpak override --user --filesystem=xdg-config/gtk-3.0
        as_user flatpak override --user --env=GTK_THEME=adw-gtk3-dark
        as_user flatpak override --user --filesystem=xdg-config/fontconfig
    fi

    temporary=$(mktemp)
    niri_portal_config_contract > "$temporary"
    install_if_changed "$temporary" "$portal_dir/portals.conf" 644
    rm -f "$temporary"
    chown -R "$TARGET_USER:" "$portal_dir"
    niri_portal_config_matches
    niri_gtk_links_match
}

deploy_wallpapers_and_templates() {
    local checkout=$1 temporary

    if [ -d "$checkout/wallpapers" ]; then
        deploy_user_tree_without_quickshell "$checkout/wallpapers" \
            "$NIRI_WALLPAPER_DIR" "$TARGET_USER" || return 1
    fi
    install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
        "$NIRI_TEMPLATES_DIR" || return 1
    niri_run_as_user "$TARGET_USER" touch "$NIRI_TEMPLATES_DIR/new" ||
        return 1
    temporary=$(mktemp) || return 1
    if ! printf '#!/usr/bin/env bash\n' > "$temporary" ||
        ! install_user_file_once "$temporary" "$NIRI_TEMPLATES_DIR/new.sh" \
            755 "$TARGET_USER"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}

main() {
    local checkout

    desktop_niri_contract_init
    checkout=$(ensure_dotfiles_checkout "$TARGET_USER" "$HOME_DIR") || return
    deploy_dotfiles "$checkout"
    configure_desktop_theme
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
