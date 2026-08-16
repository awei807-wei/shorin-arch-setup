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
    [ -f "$wallpaper" ] && [ -s "$wallpaper" ] && [ ! -L "$wallpaper" ] ||
        return 1
    [ -f "$starship" ] && [ -s "$starship" ] && [ ! -L "$starship" ] ||
        return 1
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
    local checkout=$1 source_file temporary mode

    dotfiles_source_contract "$checkout" || {
        die "Dotfiles source contract failed: $checkout"
        return 1
    }

    [ -d "$checkout/dotfiles" ] || die 'Verified checkout has no dotfiles.'
    if [ "$TARGET_USER" != shorin ]; then
        source_file="$checkout/dotfiles/.config/gtk-3.0/bookmarks"
        if [ -f "$source_file" ]; then
            temporary=$(mktemp)
            sed "s/shorin/$TARGET_USER/g" "$source_file" > "$temporary"
            install_user_file_once "$temporary" \
                "$HOME_DIR/.config/gtk-3.0/bookmarks" 644 "$TARGET_USER"
            rm -f "$temporary"
        fi
    fi

    source_file="$checkout/dotfiles/.config/niri/config.kdl"
    if [ -f "$source_file" ]; then
        temporary=$(mktemp)
        sed 's/\& \/usr\/lib\/xdg-desktop-portal-gnome//' \
            "$source_file" > "$temporary"
        install_user_file_once "$temporary" \
            "$HOME_DIR/.config/niri/config.kdl" 644 "$TARGET_USER"
        rm -f "$temporary"
    fi
    deploy_user_tree_once "$checkout/dotfiles" "$HOME_DIR" "$TARGET_USER"
    source_file="$checkout/dotfiles/.config/starship.toml"
    [ -f "$source_file" ] && [ -s "$source_file" ] && [ ! -L "$source_file" ] ||
        die 'Verified checkout has no regular Starship configuration.'
    [ "$(stat -c '%U' "$source_file")" = "$TARGET_USER" ] ||
        die 'Verified checkout has an incorrectly owned Starship configuration.'
    disable_matugen_starship_output
    mode=$(stat -c '%a' "$source_file")
    install_if_changed "$source_file" "$NIRI_STARSHIP_CONFIG_FILE" "$mode"
    chown "$TARGET_USER:" "$NIRI_STARSHIP_CONFIG_FILE"
    niri_starship_config_deployed
    # Upstream still ships unconditional sources for installer-generated files.
    # Converge them immediately so a freshly restored terminal never observes
    # a source error, even if a later desktop step fails.
    ensure_niri_fish_sources "$TARGET_USER"
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
        deploy_user_tree_once "$checkout/wallpapers" \
            "$NIRI_WALLPAPER_DIR" "$TARGET_USER"
    fi
    install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
        "$NIRI_TEMPLATES_DIR"
    as_user touch "$NIRI_TEMPLATES_DIR/new"
    temporary=$(mktemp)
    printf '#!/usr/bin/env bash\n' > "$temporary"
    install_user_file_once "$temporary" "$NIRI_TEMPLATES_DIR/new.sh" \
        755 "$TARGET_USER"
    rm -f "$temporary"
}

main() {
    local checkout

    desktop_niri_contract_init
    checkout=$(ensure_dotfiles_checkout "$TARGET_USER" "$HOME_DIR") || return
    deploy_dotfiles "$checkout"
    configure_desktop_theme
    deploy_wallpapers_and_templates "$checkout"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
