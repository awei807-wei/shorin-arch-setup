#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

deploy_dotfiles() {
    local checkout=$1 source_file temporary

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
    printf '[preferred]\ndefault=gtk\n' > "$temporary"
    install_if_changed "$temporary" "$portal_dir/portals.conf" 644
    rm -f "$temporary"
    chown -R "$TARGET_USER:$TARGET_USER" "$portal_dir"
}

deploy_wallpapers_and_templates() {
    local checkout=$1 temporary

    if [ -d "$checkout/wallpapers" ]; then
        deploy_user_tree_once "$checkout/wallpapers" \
            "$HOME_DIR/Pictures/Wallpapers" "$TARGET_USER"
    fi
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$HOME_DIR/Templates"
    as_user touch "$HOME_DIR/Templates/new"
    temporary=$(mktemp)
    printf '#!/usr/bin/env bash\n' > "$temporary"
    install_user_file_once "$temporary" "$HOME_DIR/Templates/new.sh" \
        755 "$TARGET_USER"
    rm -f "$temporary"
}

main() {
    local github=https://github.com/awei807-wei/ShorinArchExperience-ArchlinuxGuide.git
    local gitee=https://gitee.com/shorinkiwata/ShorinArchExperience-ArchlinuxGuide.git
    local checkout=/tmp/shorin-repo

    if ! ensure_git_checkout "$TARGET_USER" "$github" main "$checkout"; then
        [ ! -e "$checkout" ] ||
            die "Refusing to replace an unverified dotfiles checkout: $checkout"
        ensure_git_checkout "$TARGET_USER" "$gitee" main "$checkout"
    fi
    deploy_dotfiles "$checkout"
    configure_desktop_theme
    deploy_wallpapers_and_templates "$checkout"
}

main "$@"
