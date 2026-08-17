#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
REAL_NIRI_BIN=$(type -P niri || true)
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR=$TEST_DIR/home
SHORIN_ROOT=$ROOT_DIR
SHORIN_MODE=repair
SHORIN_READ_ONLY=0
export TARGET_USER HOME_DIR SHORIN_ROOT SHORIN_MODE SHORIN_READ_ONLY

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_equal() {
    local expected=$1 actual=$2 message=$3

    [ "$expected" = "$actual" ] ||
        fail "$message (expected=$expected actual=$actual)"
}

source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"
source "$ROOT_DIR/scripts/modules/desktop-niri/dotfiles-apply.sh"

assert_equal '/tmp/fixture-wallpaper.png' \
    "$(printf '%s\n' ': eDP-1: 1920x1080, currently displaying: image: /tmp/fixture-wallpaper.png' |
        niri_awww_query_path_from_output)" \
    'awww output parsing must accept the real display-prefixed query line'
assert_equal '' \
    "$(printf '%s\n' ': eDP-1: 1920x1080, currently displaying: color: #101010' |
        niri_awww_query_path_from_output)" \
    'awww colour query output must not be treated as an image path'

niri_user_bus_is_available() {
    return 1
}

test_dotfiles_checkout_tracks_latest_and_falls_back_safely() (
    local github_repo="$TEST_DIR/dotfiles-github"
    local gitee_repo="$TEST_DIR/dotfiles-gitee"
    local checkout="$TEST_DIR/dotfiles-checkout-latest"
    local dirty_checkout="$TEST_DIR/dotfiles-checkout-dirty"
    local untrusted_checkout="$TEST_DIR/dotfiles-checkout-untrusted"
    local current_user first_commit second_commit actual_checkout

    current_user=$(id -un)
    mkdir -p "$HOME_DIR"
    desktop_niri_contract_init
    for repository in "$github_repo" "$gitee_repo"; do
        mkdir -p "$repository"
        mkdir -p "$repository/wallpapers" \
            "$repository/dotfiles/.config/niri" \
            "$repository/dotfiles/.config/quickshell/scripts" \
            "$repository/dotfiles/.config/quickshell/lockscreen" \
            "$repository/dotfiles/.config/quickshell/config" \
            "$repository/dotfiles/.config/scripts" \
            "$repository/dotfiles/.config/matugen"
        git init -q -b main "$repository"
        printf 'gitee-first\n' > "$repository/version.txt"
        printf 'wallpaper\n' > "$repository/wallpapers/$(basename "$NIRI_DEFAULT_WALLPAPER_FILE")"
        printf 'niri\n' > "$repository/dotfiles/.config/niri/config.kdl"
        printf '#!/usr/bin/env bash\n' \
            > "$repository/dotfiles/.config/quickshell/scripts/lockscreen.sh"
        chmod 755 "$repository/dotfiles/.config/quickshell/scripts/lockscreen.sh"
        printf 'import QtQuick 2.0\n' \
            > "$repository/dotfiles/.config/quickshell/shell.qml"
        printf 'import QtQuick 2.0\n' \
            > "$repository/dotfiles/.config/quickshell/lockscreen/shell.qml"
        printf 'module Shorin.Config\n' \
            > "$repository/dotfiles/.config/quickshell/config/qmldir"
        ln -s ../config \
            "$repository/dotfiles/.config/quickshell/lockscreen/config"
        for script in matugen-select-type.sh \
            niri_set_overview_blur_dark_bg.sh niri_auto_blur_bg.sh; do
            printf '#!/usr/bin/env bash\n' \
                > "$repository/dotfiles/.config/scripts/$script"
            chmod 755 "$repository/dotfiles/.config/scripts/$script"
        done
        printf '[config.wallpaper]\ncommand = "awww"\n' \
            > "$repository/dotfiles/.config/matugen/config.toml"
        printf 'format = "repo"\n' > "$repository/dotfiles/.config/starship.toml"
        git -C "$repository" add .
        git -C "$repository" -c user.name=Fixture \
            -c user.email=fixture@example.invalid commit -q -m first
    done
    first_commit=$(git -C "$gitee_repo" rev-parse HEAD)

    runuser() {
        [ "$1" = -u ] || return 1
        shift 2
        [ "$1" = -- ] || return 1
        shift
        "$@"
    }
    eval "$(declare -f ensure_git_checkout | \
        sed 's/^ensure_git_checkout /real_ensure_git_checkout /')"
    ensure_git_checkout() {
        [ "$2" != "$github_repo" ] || return 1
        real_ensure_git_checkout "$@"
    }

    export NIRI_DOTFILES_GITHUB_URL="$github_repo"
    export NIRI_DOTFILES_GITEE_URL="$gitee_repo"
    export NIRI_DOTFILES_CHECKOUT="$checkout"
    export NIRI_DOTFILES_FALLBACK_CHECKOUT="$checkout.gitee"

    actual_checkout=$(ensure_dotfiles_checkout "$current_user" "$HOME_DIR") ||
        fail 'GitHub failure must fall back to a fresh Gitee main checkout'
    [ "$actual_checkout" = "$checkout.gitee" ] ||
        fail 'Gitee fallback must report its selected checkout path'
    assert_equal main "$(git -C "$actual_checkout" branch --show-current)" \
        'Gitee fallback must use main rather than a detached commit'
    assert_equal "$first_commit" "$(git -C "$actual_checkout" rev-parse HEAD)" \
        'Gitee fallback must start at the latest main commit'

    printf 'gitee-second\n' > "$gitee_repo/version.txt"
    git -C "$gitee_repo" add version.txt
    git -C "$gitee_repo" -c user.name=Fixture \
        -c user.email=fixture@example.invalid commit -q -m second
    second_commit=$(git -C "$gitee_repo" rev-parse HEAD)
    actual_checkout=$(ensure_dotfiles_checkout "$current_user" "$HOME_DIR") ||
        fail 'a second run must update the trusted Gitee checkout'
    assert_equal "$second_commit" "$(git -C "$actual_checkout" rev-parse HEAD)" \
        'a second fallback run must follow Gitee origin/main'
    actual_checkout=$(ensure_dotfiles_checkout "$current_user" "$HOME_DIR") ||
        fail 'a converged fallback run must remain idempotent'
    assert_equal "$second_commit" "$(git -C "$actual_checkout" rev-parse HEAD)" \
        'an idempotent fallback run must not move the checkout unexpectedly'

    git clone -q "$github_repo" "$dirty_checkout"
    printf 'dirty\n' >> "$dirty_checkout/version.txt"
    export NIRI_DOTFILES_CHECKOUT="$dirty_checkout"
    export NIRI_DOTFILES_FALLBACK_CHECKOUT="$TEST_DIR/unused-gitee"
    if ensure_dotfiles_checkout "$current_user" "$HOME_DIR"; then
        fail 'a dirty existing GitHub checkout must be refused'
    fi

    mkdir -p "$untrusted_checkout"
    printf 'sentinel\n' > "$untrusted_checkout/sentinel"
    export NIRI_DOTFILES_CHECKOUT="$untrusted_checkout"
    if ensure_dotfiles_checkout "$current_user" "$HOME_DIR"; then
        fail 'an untrusted non-Git checkout must be refused'
    fi
    [ "$(< "$untrusted_checkout/sentinel")" = sentinel ] ||
        fail 'an untrusted checkout path must not be replaced'

    unset -f ensure_git_checkout real_ensure_git_checkout runuser
    unset NIRI_DOTFILES_GITHUB_URL NIRI_DOTFILES_GITEE_URL \
        NIRI_DOTFILES_CHECKOUT NIRI_DOTFILES_FALLBACK_CHECKOUT
)

test_dotfiles_checkout_tracks_latest_and_falls_back_safely

desktop_niri_contract_init
DOTFILES_CHECKOUT="$TEST_DIR/dotfiles-checkout"
mkdir -p "$DOTFILES_CHECKOUT/dotfiles/.config/fish/conf.d"
mkdir -p "$DOTFILES_CHECKOUT/dotfiles/.config/matugen/templates"
mkdir -p "$DOTFILES_CHECKOUT/dotfiles/.config/niri" \
    "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/scripts" \
    "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/lockscreen" \
    "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/config" \
    "$DOTFILES_CHECKOUT/dotfiles/.config/scripts" \
    "$DOTFILES_CHECKOUT/wallpapers"
printf 'niri source\n' > "$DOTFILES_CHECKOUT/dotfiles/.config/niri/config.kdl"
printf '#!/usr/bin/env bash\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/scripts/lockscreen.sh"
chmod 755 "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/scripts/lockscreen.sh"
printf 'import QtQuick 2.0\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/shell.qml"
printf 'import QtQuick 2.0\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/lockscreen/shell.qml"
printf 'command: ["sh", "-c", "awww query"]\n' \
    >> "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/lockscreen/shell.qml"
printf 'property string swwwTheme: "preserve-identifier"\n' \
    >> "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/lockscreen/shell.qml"
printf 'module Shorin.Config\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/config/qmldir"
ln -s ../config \
    "$DOTFILES_CHECKOUT/dotfiles/.config/quickshell/lockscreen/config"
for script in matugen-select-type.sh \
    niri_set_overview_blur_dark_bg.sh niri_auto_blur_bg.sh; do
    printf '#!/usr/bin/env bash\n' \
        > "$DOTFILES_CHECKOUT/dotfiles/.config/scripts/$script"
    chmod 755 "$DOTFILES_CHECKOUT/dotfiles/.config/scripts/$script"
done
printf '[config.wallpaper]\ncommand = "awww"\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/matugen/config.toml"
printf 'wallpaper source\n' > \
    "$DOTFILES_CHECKOUT/wallpapers/$(basename "$HOME_DIR/Pictures/Wallpapers/black-and-white-3840x2160-21293.jpg")"
printf 'source "$HOME/.cargo/env.fish"\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/fish/conf.d/rustup.fish"
printf '\nsource "$HOME/.local/bin/env.fish"\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/fish/conf.d/uv.env.fish"
printf 'format = "$directory$character"\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml"
cat > "$DOTFILES_CHECKOUT/dotfiles/.config/matugen/config.toml" <<'EOF'
[config.wallpaper]
command = "awww"

[templates.starship]
input_path = '~/.config/matugen/templates/starship-colors.toml'
output_path = '~/.config/starship.toml'

[templates.yazi]
input_path = '~/.config/matugen/templates/yazi-theme.toml'
output_path = '~/.config/yazi/theme.toml'
EOF
printf 'legacy Matugen Starship template\n' \
    > "$DOTFILES_CHECKOUT/dotfiles/.config/matugen/templates/starship-colors.toml"
git init -q -b main "$DOTFILES_CHECKOUT"
git -C "$DOTFILES_CHECKOUT" add .
git -C "$DOTFILES_CHECKOUT" -c user.name=Fixture \
    -c user.email=fixture@example.invalid commit -q -m fixture
deploy_dotfiles "$DOTFILES_CHECKOUT"
[ -L "$NIRI_QUICKSHELL_DIR/lockscreen/config" ] &&
    [ "$(readlink "$NIRI_QUICKSHELL_DIR/lockscreen/config")" = ../config ] ||
    fail 'QuickShell deployment must preserve internal directory symlinks'
niri_fish_sources_satisfied ||
    fail 'dotfile deployment must immediately remove unsafe Fish environment sources'

test_dotfiles_transaction_rolls_back_late_failure() (
    local before_quickshell="$TEST_DIR/txn-before-quickshell"
    local before_state="$TEST_DIR/txn-before-state"
    local before_matugen="$TEST_DIR/txn-before-matugen"
    local before_fish="$TEST_DIR/txn-before-fish"

    cp -a "$NIRI_QUICKSHELL_DIR" "$before_quickshell"
    cp -a "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$before_state"
    cp -a "$NIRI_MATUGEN_CONFIG_FILE" "$before_matugen"
    cp -a "$NIRI_FISH_CONFIG_FILE" "$before_fish"
    niri_deploy_wallpaper_compat_file() { return 1; }
    if deploy_dotfiles "$DOTFILES_CHECKOUT"; then
        fail 'a late Fedora wallpaper conversion failure must fail the dotfile transaction'
    fi
    diff -qr --no-dereference "$before_quickshell" "$NIRI_QUICKSHELL_DIR" >/dev/null ||
        fail 'a late dotfile failure must restore the QuickShell tree'
    cmp -s "$before_state" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ||
        fail 'a late dotfile failure must restore QuickShell source state'
    cmp -s "$before_matugen" "$NIRI_MATUGEN_CONFIG_FILE" ||
        fail 'a late dotfile failure must restore Matugen configuration'
    cmp -s "$before_fish" "$NIRI_FISH_CONFIG_FILE" ||
        fail 'a late dotfile failure must restore Fish configuration'
)

test_dotfiles_transaction_rolls_back_late_failure

test_quickshell_state_failure_rolls_back_tree() (
    local stage="$TEST_DIR/quickshell-failing-stage"
    local before_quickshell="$TEST_DIR/quickshell-state-before-tree"
    local before_state="$TEST_DIR/quickshell-state-before-state"
    local real_install_if_changed

    cp -a "$NIRI_QUICKSHELL_DIR" "$before_quickshell"
    cp -a "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$before_state"
    cp -a "$NIRI_QUICKSHELL_DIR" "$stage"
    printf 'state failure fixture\n' > "$stage/shell.qml"
    real_install_if_changed=$(declare -f install_if_changed)
    eval "${real_install_if_changed/install_if_changed/real_install_if_changed}"
    install_if_changed() {
        [ "$2" = "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] && return 1
        real_install_if_changed "$@"
    }
    if niri_quickshell_atomic_replace "$stage" "$TARGET_USER" \
        test-commit arch; then
        fail 'a QuickShell source-state installation failure must fail deployment'
    fi
    diff -qr --no-dereference "$before_quickshell" "$NIRI_QUICKSHELL_DIR" >/dev/null ||
        fail 'a QuickShell state failure must restore the old tree'
    cmp -s "$before_state" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ||
        fail 'a QuickShell state failure must restore the old state file'
)

test_quickshell_state_failure_rolls_back_tree

test_quickshell_old_hold_cleanup_is_nonfatal() (
    local stage="$TEST_DIR/quickshell-hold-stage"
    local real_remove_tree old_hold

    cp -a "$NIRI_QUICKSHELL_DIR" "$stage"
    printf 'old-hold cleanup fixture\n' > "$stage/shell.qml"
    real_remove_tree=$(declare -f niri_quickshell_remove_tree)
    eval "${real_remove_tree/niri_quickshell_remove_tree/real_remove_tree}"
    niri_quickshell_remove_tree() {
        case "$1" in
            *.quickshell-old.*) return 1 ;;
            *) real_remove_tree "$@" ;;
        esac
    }
    niri_quickshell_atomic_replace "$stage" "$TARGET_USER" \
        hold-cleanup-commit arch ||
        fail 'an old QuickShell hold cleanup failure must not fail a successful deployment'
    niri_quickshell_deployment_state_satisfied ||
        fail 'an old QuickShell hold cleanup failure must leave tree/state consistent'
    old_hold=$(find "$(dirname "$NIRI_QUICKSHELL_DIR")" -maxdepth 1 \
        -type d -name '.quickshell-old.*' -print -quit)
    [ -n "$old_hold" ] ||
        fail 'a failed old hold cleanup should leave the hold available for recovery'
    real_remove_tree "$old_hold"
)

test_quickshell_old_hold_cleanup_is_nonfatal

test_quickshell_drift_is_not_re_registered() (
    local before_state="$TEST_DIR/quickshell-drift-before-state"
    local before_quickshell="$TEST_DIR/quickshell-drift-before-tree"

    cp -a "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$before_state"
    cp -a "$NIRI_QUICKSHELL_DIR" "$before_quickshell"
    printf '%s\n' 'import QtQuick 2.0' 'property string tampered: "drift"' \
        > "$NIRI_QUICKSHELL_DIR/shell.qml"
    if niri_quickshell_refresh_state_digest; then
        fail 'a hand-edited QuickShell tree must not refresh its source digest'
    fi
    cmp -s "$before_state" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ||
        fail 'a rejected QuickShell drift must preserve source state'
    if ensure_niri_session_config "$TARGET_USER"; then
        fail 'session apply must reject an unregistered QuickShell drift'
    fi
    if niri_quickshell_deployment_state_satisfied; then
        fail 'a rejected QuickShell drift must remain unsatisfied'
    fi

    niri_quickshell_stage_and_deploy "$DOTFILES_CHECKOUT" "$TARGET_USER" ||
        fail 'QuickShell repair must redeploy the verified source tree'
    niri_quickshell_deployment_state_satisfied ||
        fail 'source redeployment must restore the QuickShell deployment contract'
)

test_quickshell_drift_is_not_re_registered

test_fedora_quickshell_conversion_is_staged() (
    local fedora_home="$TEST_DIR/fedora-quickshell-home"
    local fedora_checkout="$TEST_DIR/fedora-quickshell-checkout"

    export SHORIN_DISTRO=fedora HOME_DIR="$fedora_home"
    unset NIRI_QUICKSHELL_DIR NIRI_DESKTOP_STATE_DIR \
        NIRI_QUICKSHELL_BACKUP_DIR NIRI_QUICKSHELL_SOURCE_STATE_FILE
    desktop_niri_contract_init
    cp -a "$DOTFILES_CHECKOUT" "$fedora_checkout"
    cat > "$fedora_checkout/dotfiles/.config/quickshell/lockscreen/shell.qml" <<'EOF'
import QtQuick 2.0
property string wallpaper: "swww query"
EOF
    niri_quickshell_stage_and_deploy "$fedora_checkout" "$TARGET_USER" ||
        fail 'Fedora QuickShell conversion must succeed in staging'
    ! niri_tree_has_legacy_swww "$NIRI_QUICKSHELL_DIR" ||
        fail 'Fedora live QuickShell must contain only staged wallpaper conversion'
    niri_quickshell_deployment_state_satisfied ||
        fail 'Fedora staged QuickShell conversion must satisfy deployment state'
    printf '%s\n' 'import QtQuick 2.0' 'property string tampered: "drift"' \
        > "$NIRI_QUICKSHELL_DIR/shell.qml"
    if niri_quickshell_refresh_state_digest; then
        fail 'Fedora session refresh must reject a hand-edited QuickShell tree'
    fi
    if niri_quickshell_deployment_state_satisfied; then
        fail 'Fedora hand-edited QuickShell must remain unsatisfied'
    fi
)

test_fedora_quickshell_conversion_is_staged
export SHORIN_DISTRO=arch
desktop_niri_contract_init

[ ! -e "$HOME_DIR/.config/fish/conf.d/uv.env.fish" ] ||
    fail 'the upstream Fish source with a leading blank line must be migrated'
niri_starship_config_deployed ||
    fail 'dotfile deployment must restore the Starship configuration'

STARSHIP_TARGET_COPY="$TEST_DIR/starship-target-copy.toml"
cp "$NIRI_STARSHIP_CONFIG_FILE" "$STARSHIP_TARGET_COPY"
rm -f "$NIRI_STARSHIP_CONFIG_FILE"
mkdir "$NIRI_STARSHIP_CONFIG_FILE"
if niri_starship_config_deployed; then
    fail 'a Starship target directory must not satisfy the file contract'
fi
rmdir "$NIRI_STARSHIP_CONFIG_FILE"
mkfifo "$NIRI_STARSHIP_CONFIG_FILE"
if niri_starship_config_deployed; then
    fail 'a Starship target FIFO must not satisfy the file contract'
fi
rm -f "$NIRI_STARSHIP_CONFIG_FILE"
mv "$STARSHIP_TARGET_COPY" "$NIRI_STARSHIP_CONFIG_FILE"

STARSHIP_SOURCE_COPY="$TEST_DIR/starship-source-copy.toml"
mv "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml" "$STARSHIP_SOURCE_COPY"
mkdir "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml"
if deploy_dotfiles "$DOTFILES_CHECKOUT"; then
    fail 'a Starship source directory must fail the source contract'
fi
rmdir "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml"
mkfifo "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml"
if deploy_dotfiles "$DOTFILES_CHECKOUT"; then
    fail 'a Starship source FIFO must fail the source contract'
fi
rm -f "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml"
mv "$STARSHIP_SOURCE_COPY" "$DOTFILES_CHECKOUT/dotfiles/.config/starship.toml"

OLD_WALLPAPER="$HOME_DIR/Pictures/Wallpapers/old-wallpaper.jpg"
mkdir -p "$HOME_DIR/Pictures/Wallpapers"
printf 'old user wallpaper\n' > "$OLD_WALLPAPER"
MISSING_WALLPAPER_CHECKOUT="$TEST_DIR/missing-wallpaper-checkout"
cp -a "$DOTFILES_CHECKOUT" "$MISSING_WALLPAPER_CHECKOUT"
rm -f "$MISSING_WALLPAPER_CHECKOUT/wallpapers/$(basename "$NIRI_DEFAULT_WALLPAPER_FILE")"
if deploy_dotfiles "$MISSING_WALLPAPER_CHECKOUT"; then
    fail 'a checkout missing the default wallpaper must fail despite an old home wallpaper'
fi
[ "$(< "$OLD_WALLPAPER")" = 'old user wallpaper' ] ||
    fail 'a failed wallpaper source check must preserve the old home wallpaper'

MISSING_CORE_CHECKOUT="$TEST_DIR/missing-core-checkout"
cp -a "$DOTFILES_CHECKOUT" "$MISSING_CORE_CHECKOUT"
rm -f "$MISSING_CORE_CHECKOUT/dotfiles/.config/niri/config.kdl"
rmdir "$MISSING_CORE_CHECKOUT/dotfiles/.config/niri"
if deploy_dotfiles "$MISSING_CORE_CHECKOUT"; then
    fail 'a checkout missing the Niri core directory must fail closed'
fi

MISSING_LOCKSCREEN_CHECKOUT="$TEST_DIR/missing-lockscreen-checkout"
cp -a "$DOTFILES_CHECKOUT" "$MISSING_LOCKSCREEN_CHECKOUT"
rm -f "$MISSING_LOCKSCREEN_CHECKOUT/dotfiles/.config/quickshell/scripts/lockscreen.sh"
if deploy_dotfiles "$MISSING_LOCKSCREEN_CHECKOUT"; then
    fail 'a checkout missing the executable lockscreen source must fail closed'
fi

niri_matugen_starship_output_disabled ||
    fail 'dotfile deployment must disable Matugen Starship output'
[ ! -e "$NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE" ] ||
    fail 'dotfile deployment must retire the unused Matugen Starship template'
grep -Fqx '[templates.yazi]' "$NIRI_MATUGEN_CONFIG_FILE" ||
    fail 'disabling Starship output must preserve later Matugen templates'

STARSHIP_CURRENT_COPY="$TEST_DIR/starship-current.toml"
cp "$HOME_DIR/.config/starship.toml" "$STARSHIP_CURRENT_COPY"
printf 'Matugen-generated Starship configuration\n' \
    > "$HOME_DIR/.config/starship.toml"
cat >> "$NIRI_MATUGEN_CONFIG_FILE" <<'EOF'

[templates.starship]
input_path = '~/.config/matugen/templates/starship-colors.toml'
output_path = '~/.config/starship.toml'
EOF
deploy_dotfiles "$DOTFILES_CHECKOUT"
cmp -s "$HOME_DIR/.config/starship.toml" "$STARSHIP_CURRENT_COPY" ||
    fail 'the verified Starship configuration must replace generated drift'
niri_matugen_starship_output_disabled ||
    fail 'reintroduced Matugen Starship output must be removed'
printf 'user-owned Starship configuration\n' > "$HOME_DIR/.config/starship.toml"
deploy_dotfiles "$DOTFILES_CHECKOUT"
cmp -s "$HOME_DIR/.config/starship.toml" "$STARSHIP_CURRENT_COPY" ||
    fail 'Starship must remain managed by the verified checkout'
cp "$STARSHIP_CURRENT_COPY" "$HOME_DIR/.config/starship.toml"
desktop_niri_contract_init

LIST_FILE="$TEST_DIR/niri-applist.txt"
MANIFEST="$TEST_DIR/niri-packages.list"
printf 'waybar\n' > "$LIST_FILE"
printf '%s\n' imv AUR:matugen waybar \
    AUR:wlogout \
    AUR:waybar-niri-taskbar-git \
    AUR:waybar-module-pacman-updates-git > "$MANIFEST"

EMPTY_MANIFEST="$TEST_DIR/empty-niri-packages.list"
: > "$EMPTY_MANIFEST"
mapfile -t EMPTY_TARGETS < <(niri_all_package_targets "$EMPTY_MANIFEST" "$LIST_FILE")
printf '%s\n' "${EMPTY_TARGETS[@]}" | grep -Fqx quickshell ||
    fail 'an empty saved manifest must retain required desktop targets'
if printf '%s\n' "${EMPTY_TARGETS[@]}" | grep -Fqx waybar; then
    fail 'an empty saved manifest must not fall back to default optional targets'
fi

mapfile -t TARGETS < <(niri_all_package_targets "$MANIFEST" "$LIST_FILE")
for REQUIRED_TARGET in quickshell qt6-wayland qt6-multimedia bluez-utils \
    matugen awww swayidle AUR:swaylock-effects; do
    printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$REQUIRED_TARGET" ||
        fail "an old manifest must not mask required target $REQUIRED_TARGET"
done
printf '%s\n' "${TARGETS[@]}" | grep -Fqx imv ||
    fail 'saved optional package choices must be preserved'
printf '%s\n' "${TARGETS[@]}" | grep -Fqx AUR:wlogout-git ||
    fail 'the legacy signed wlogout target must migrate to wlogout-git'
if printf '%s\n' "${TARGETS[@]}" | grep -Fqx AUR:wlogout; then
    fail 'the legacy wlogout target must not remain in the converged profile'
fi
printf '%s\n' "${TARGETS[@]}" | grep -Fqx matugen ||
    fail 'the required repository source must win over a stale AUR declaration'
if printf '%s\n' "${TARGETS[@]}" | grep -Fqx AUR:matugen; then
    fail 'a stale source declaration must not duplicate a required package'
fi
if printf '%s\n' "${TARGETS[@]}" | grep -Fqx waybar; then
    fail 'a legacy Waybar target must be retired when QuickShell is required'
fi
for RETIRED_TARGET in AUR:waybar-niri-taskbar-git \
    AUR:waybar-module-pacman-updates-git; do
    if printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$RETIRED_TARGET"; then
        fail "a legacy QuickShell-conflicting target must be retired: $RETIRED_TARGET"
    fi
done

mkdir -p "$HOME_DIR/.config/niri"
NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
cat > "$NIRI_CONFIG" <<'EOF'
// user-owned marker
spawn-at-startup "waybar"
spawn-at-startup "quickshell" "--config" "user-shell"
spawn-at-startup "quickshell"
spawn-at-startup "ags" "run"
spawn-at-startup "/usr/bin/fcitx5" "-d"
spawn-at-startup "env" "fcitx5"
binds {
    Mod+Return { spawn "kitty"; }
}
EOF

ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
ensure_niri_fcitx5_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_quickshell_startup_satisfied "$NIRI_CONFIG" ||
    fail 'converged config must contain one conflict-free QuickShell startup'
grep -Fqx '// user-owned marker' "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve unrelated user content'
grep -Fqx '    Mod+Return { spawn "kitty"; }' "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve user key bindings'
niri_fcitx5_startup_satisfied "$NIRI_CONFIG" ||
    fail 'converged config must contain exactly one Fcitx5 startup'
[ "$(grep -Ec '^[[:space:]]*spawn(-sh)?-at-startup.*fcitx5' "$NIRI_CONFIG")" -eq 1 ] ||
    fail 'Fcitx5 convergence must remove duplicate startup commands'
grep -Fqx 'spawn-at-startup "quickshell" "--config" "user-shell"' \
    "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve the first user command and arguments'
grep -Fqx 'spawn-at-startup "quickshell"' "$NIRI_CONFIG" ||
    fail 'additional QuickShell instances (e.g. a lockscreen) must be preserved'
FIRST_COPY="$TEST_DIR/first-config.kdl"
cp "$NIRI_CONFIG" "$FIRST_COPY"
ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
cmp -s "$FIRST_COPY" "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must be content-idempotent'

printf '%s\n' 'spawn-sh-at-startup "quickshell &"' > "$NIRI_CONFIG"
ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
grep -Fqx 'spawn-sh-at-startup "quickshell &"' "$NIRI_CONFIG" ||
    fail 'an existing spawn-sh QuickShell command must be preserved'
[ "$(grep -Ec '^[[:space:]]*spawn(-sh)?-at-startup.*quickshell' "$NIRI_CONFIG")" -eq 1 ] ||
    fail 'spawn-sh QuickShell must not be duplicated'

printf '// arbitrary but nonempty config\n' > "$NIRI_CONFIG"
if niri_quickshell_startup_satisfied "$NIRI_CONFIG"; then
    fail 'a nonempty config without QuickShell startup must not verify'
fi
ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_quickshell_startup_satisfied "$NIRI_CONFIG" ||
    fail 'QuickShell startup must be added without replacing the config'
grep -Fqx '// arbitrary but nonempty config' "$NIRI_CONFIG" ||
    fail 'startup insertion must preserve the existing config'
ensure_niri_fcitx5_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_fcitx5_startup_satisfied "$NIRI_CONFIG" ||
    fail 'Fcitx5 startup must be added without replacing the config'

NIRI_FIREFOX_POLICY_FILE="$TEST_DIR/firefox/policies.json"
NIRI_NAUTILUS_VENDOR_FILE="$TEST_DIR/vendor-nautilus.desktop"
NIRI_NAUTILUS_OVERRIDE_FILE="$HOME_DIR/.local/share/applications/org.gnome.Nautilus.desktop"
NIRI_GNOME_TERMINAL_LINK="$HOME_DIR/.local/bin/gnome-terminal"
NIRI_GNOME_TERMINAL_TARGET="$TEST_DIR/bin/kitty"
NIRI_PORTAL_CONFIG_FILE="$HOME_DIR/.config/xdg-desktop-portal/portals.conf"
NIRI_GTK4_DIR="$HOME_DIR/.config/gtk-4.0"
NIRI_GTK_THEME_DIR="$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0"
NIRI_WAYPAPER_CONFIG_FILE="$HOME_DIR/.config/waypaper/config.ini"
NIRI_BINDS_FILE="$HOME_DIR/.config/niri/binds.kdl"
NIRI_QUICKSHELL_DIR="$HOME_DIR/.config/quickshell"
NIRI_FISH_GUARD_FILE="$HOME_DIR/.config/fish/conf.d/shorin-env.fish"
NIRI_FISH_RUSTUP_FILE="$HOME_DIR/.config/fish/conf.d/rustup.fish"
NIRI_FISH_LOCAL_ENV_FILE="$HOME_DIR/.config/fish/conf.d/uv.env.fish"
NIRI_BASH_PROFILE="$HOME_DIR/.bash_profile"
NIRI_LEGACY_UNIT="$HOME_DIR/.config/systemd/user/niri-autostart.service"
NIRI_LEGACY_UNIT_LINK="$HOME_DIR/.config/systemd/user/default.target.wants/niri-autostart.service"
NIRI_AUTOLOGIN_FILE="$TEST_DIR/getty@tty1.service.d/autologin.conf"
export NIRI_FIREFOX_POLICY_FILE NIRI_NAUTILUS_VENDOR_FILE
export NIRI_NAUTILUS_OVERRIDE_FILE NIRI_GNOME_TERMINAL_LINK
export NIRI_GNOME_TERMINAL_TARGET NIRI_PORTAL_CONFIG_FILE
export NIRI_GTK4_DIR NIRI_GTK_THEME_DIR
export NIRI_WAYPAPER_CONFIG_FILE
export NIRI_BINDS_FILE NIRI_QUICKSHELL_DIR NIRI_FISH_GUARD_FILE
export NIRI_FISH_RUSTUP_FILE
export NIRI_FISH_LOCAL_ENV_FILE NIRI_BASH_PROFILE NIRI_LEGACY_UNIT
export NIRI_LEGACY_UNIT_LINK
export NIRI_AUTOLOGIN_FILE
desktop_niri_contract_init

# A directory or stylesheet-like path at the Waypaper config location is not
# a valid config file and must never satisfy the backend contract.
mkdir -p "$NIRI_WAYPAPER_CONFIG_FILE"
if niri_waypaper_backend_satisfied; then
    fail 'a Waypaper config directory must not satisfy the backend contract'
fi
rmdir "$NIRI_WAYPAPER_CONFIG_FILE"

mkdir -p "$(dirname "$NIRI_FIREFOX_POLICY_FILE")" \
    "$(dirname "$NIRI_NAUTILUS_OVERRIDE_FILE")" \
    "$(dirname "$NIRI_GNOME_TERMINAL_LINK")" \
    "$(dirname "$NIRI_GNOME_TERMINAL_TARGET")" \
    "$NIRI_GTK4_DIR" "$NIRI_GTK_THEME_DIR" \
    "$(dirname "$NIRI_PORTAL_CONFIG_FILE")" \
    "$(dirname "$NIRI_WAYPAPER_CONFIG_FILE")" \
    "$NIRI_QUICKSHELL_DIR/lockscreen" \
    "$(dirname "$NIRI_FISH_RUSTUP_FILE")" \
    "$(dirname "$NIRI_LEGACY_UNIT_LINK")"
printf 'stale override\n' > "$NIRI_NAUTILUS_OVERRIDE_FILE"
status=0
niri_nautilus_override_matches || status=$?
[ "$status" -eq 1 ] ||
    fail 'a missing Nautilus vendor file must be repairable desktop drift'
rm -f "$NIRI_NAUTILUS_OVERRIDE_FILE"
cat > "$NIRI_NAUTILUS_VENDOR_FILE" <<'EOF'
[Desktop Entry]
Name=Files
DBusActivatable=true
Exec=nautilus --new-window %U

[Desktop Action new-window]
Exec=nautilus --new-window
EOF
status=0
niri_user_terminal_link_matches || status=$?
[ "$status" -eq 1 ] ||
    fail 'a missing Kitty target must be repairable desktop drift'
printf '#!/usr/bin/env bash\n' > "$NIRI_GNOME_TERMINAL_TARGET"
chmod 755 "$NIRI_GNOME_TERMINAL_TARGET"

# Keep the fixture independent of the host GPU topology.
lspci() {
    return 0
}
export -f lspci

niri_firefox_policy_contract > "$NIRI_FIREFOX_POLICY_FILE"
niri_nautilus_override_contract > "$NIRI_NAUTILUS_OVERRIDE_FILE"
ln -s "$NIRI_GNOME_TERMINAL_TARGET" "$NIRI_GNOME_TERMINAL_LINK"
niri_portal_config_contract > "$NIRI_PORTAL_CONFIG_FILE"
printf 'gtk css\n' > "$NIRI_GTK_THEME_DIR/gtk.css"
printf 'gtk dark css\n' > "$NIRI_GTK_THEME_DIR/gtk-dark.css"
ln -s "$NIRI_GTK_THEME_DIR/gtk.css" "$NIRI_GTK4_DIR/gtk.css"
ln -s "$NIRI_GTK_THEME_DIR/gtk-dark.css" "$NIRI_GTK4_DIR/gtk-dark.css"

cat > "$NIRI_CONFIG_FILE" <<'EOF'
// preserve niri marker
environment {
    PATH "/usr/local/bin:/usr/bin"
}
spawn-at-startup "swww-daemon"
spawn-at-startup "quickshell"
EOF
cat > "$NIRI_BINDS_FILE" <<'EOF'
binds {
    Mod+Alt+V { spawn "clipse"; }
    Mod+ALT+V { spawn "old-clipboard"; }
    Mod+Alt+C { spawn "old-switcher"; }
    Mod+Return { spawn "kitty"; }
}
EOF
cat > "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" <<'EOF'
property string swwwTheme: "preserve-identifier"
command: ["sh", "-c", "swww query"]
EOF
cat > "$NIRI_WAYPAPER_CONFIG_FILE" <<'EOF'
[Settings]
folder = ~/Pictures/Wallpapers
backend = swww
stylesheet = ~/.config/waypaper/style.css
swww_transition_type = any
EOF
printf 'source "$HOME/.cargo/env.fish"\n' > "$NIRI_FISH_RUSTUP_FILE"
printf 'test -f "$HOME/.local/bin/env.fish"; and source "$HOME/.local/bin/env.fish"\n' \
    > "$NIRI_FISH_LOCAL_ENV_FILE"
cat > "$NIRI_BASH_PROFILE" <<'EOF'
# preserve profile marker
# shorin:niri-session:start
if [ "$(tty)" = /dev/tty1 ]; then
    exec niri-session
fi
# shorin:niri-session:end
# preserve profile tail
EOF
printf '[Service]\nExecStart=/usr/bin/niri-session\n' > "$NIRI_LEGACY_UNIT"
ln -s ../niri-autostart.service "$NIRI_LEGACY_UNIT_LINK"
niri_quickshell_stage_and_deploy "$DOTFILES_CHECKOUT" "$TARGET_USER" ||
    fail 'the active QuickShell fixture must be restored from verified source'

VALIDATE_BIN_DIR="$TEST_DIR/validate-bin"
NIRI_VALIDATE_LOG="$TEST_DIR/niri-validate.log"
mkdir -p "$VALIDATE_BIN_DIR"
cat > "$VALIDATE_BIN_DIR/niri" <<'EOF'
#!/usr/bin/env bash
[ "$1" = validate ] && [ "$2" = -c ] && [ -s "$3" ]
[ "${NIRI_VALIDATE_FAIL:-0}" != 1 ] || exit 1
printf 'validated\n' >> "$NIRI_VALIDATE_LOG"
EOF
chmod +x "$VALIDATE_BIN_DIR/niri"
export NIRI_VALIDATE_LOG
PATH="$VALIDATE_BIN_DIR:$PATH"
export PATH
RUNUSER_VALIDATE_LOG="$TEST_DIR/runuser-validate.log"
runuser() {
    printf '%s\n' "$*" >> "$RUNUSER_VALIDATE_LOG"
    [ "$1" = -u ] && [ "$3" = -- ] || return 2
    shift 3
    "$@"
}
SHORIN_FORCE_RUNUSER=1
export SHORIN_FORCE_RUNUSER

ensure_niri_session_config "$TARGET_USER"
niri_path_satisfied || fail 'Niri PATH must contain the target user local bin'
niri_wallpaper_backend_satisfied || fail 'Niri startup must migrate swww to awww'
niri_quickshell_wallpaper_backend_satisfied ||
    fail 'QuickShell commands must migrate swww to awww'
niri_waypaper_backend_satisfied ||
    fail 'Waypaper must use the installed awww backend'
grep -Fqx 'folder = ~/Pictures/Wallpapers' "$NIRI_WAYPAPER_CONFIG_FILE" ||
    fail 'Waypaper folder setting must survive backend migration'
grep -Fqx 'stylesheet = ~/.config/waypaper/style.css' \
    "$NIRI_WAYPAPER_CONFIG_FILE" ||
    fail 'Waypaper stylesheet setting must survive backend migration'
niri_bindings_satisfied || fail 'Niri clipboard and FocusShift bindings must be exact'
niri_fish_sources_satisfied || fail 'Fish environment sources must be conditional'
niri_fish_config_satisfied || fail 'the managed Fish config block must satisfy its static contract'
[ -f "$NIRI_FISH_GUARD_FILE" ] ||
    fail 'Fish guards must use a dedicated installer-managed conf.d file'
grep -Fqx '    set -gx PATH "$HOME/.cargo/bin" $PATH' "$NIRI_FISH_GUARD_FILE" ||
    fail 'managed Fish environment must add Cargo bin without generated env files'
grep -Fqx '    set -gx PATH "$HOME/.local/bin" $PATH' "$NIRI_FISH_GUARD_FILE" ||
    fail 'managed Fish environment must add local bin without generated env files'
if grep -Fq 'source "$HOME/' "$NIRI_FISH_GUARD_FILE"; then
    fail 'managed Fish environment must not depend on installer-generated env files'
fi
[ ! -e "$NIRI_FISH_RUSTUP_FILE" ] && [ ! -e "$NIRI_FISH_LOCAL_ENV_FILE" ] ||
    fail 'known legacy Fish source files must be migrated without duplicate sourcing'

FISH_CONFIG_USER_COPY="$TEST_DIR/fish-config-user-copy"
cat > "$NIRI_FISH_CONFIG_FILE" <<'EOF'
# user content before the managed block
if test "$USER_CUSTOM_CONDITION" = preserved
    starship init fish | source
end
# >>> shorin fish init >>>
if status is-interactive
    starship init fish | source
# deliberately incomplete managed block
EOF
cp "$NIRI_FISH_CONFIG_FILE" "$FISH_CONFIG_USER_COPY"
if ensure_niri_fish_config "$TARGET_USER"; then
    fail 'an unclosed Fish marker block must fail safely'
fi
cmp -s "$FISH_CONFIG_USER_COPY" "$NIRI_FISH_CONFIG_FILE" ||
    fail 'an unclosed Fish marker block must remain byte-for-byte unchanged'
cat > "$NIRI_FISH_CONFIG_FILE" <<'EOF'
# user content before the managed block
if test "$USER_CUSTOM_CONDITION" = preserved
    starship init fish | source
end
# >>> shorin fish init >>>
old managed content
# <<< shorin fish init <<<
# user content after the managed block
EOF
ensure_niri_fish_config "$TARGET_USER" ||
    fail 'a closed Fish marker block must converge'
grep -Fqx '# user content before the managed block' "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish convergence must preserve user content before the managed block'
grep -Fqx '# user content after the managed block' "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish convergence must preserve user content after the managed block'
grep -Fqx '        set -l thefuck_alias (thefuck --alias 2>/dev/null)' \
    "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish thefuck guard must suppress stderr and capture its output'
grep -Fqx '        if test $status -eq 0; and test (count $thefuck_alias) -gt 0' \
    "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish thefuck guard must require successful non-empty output'

# Only the three exact, top-level legacy commands are installer-owned.  The
# same text inside user functions/conditions must remain untouched, while a
# static contract check must reject any top-level residue before apply.
cat > "$NIRI_FISH_CONFIG_FILE" <<'EOF'
starship init fish | source
zoxide init fish --cmd cd | source
thefuck --alias | source
if test "$USER_CUSTOM_CONDITION" = preserved
    starship init fish | source
end
function user_custom_fish_init
    zoxide init fish --cmd cd | source
end
begin
    thefuck --alias | source
end
# >>> shorin fish init >>>
old managed content
# <<< shorin fish init <<<
EOF
if niri_fish_config_satisfied; then
    fail 'Fish static contract must reject top-level legacy initialization lines'
fi
ensure_niri_fish_config "$TARGET_USER" ||
    fail 'Fish apply must remove exact top-level legacy initialization lines'
niri_fish_config_satisfied ||
    fail 'Fish static contract must accept the cleaned managed configuration'
for legacy_line in \
    'starship init fish | source' \
    'zoxide init fish --cmd cd | source' \
    'thefuck --alias | source'; do
    if grep -Fqx "$legacy_line" "$NIRI_FISH_CONFIG_FILE"; then
        fail "Fish top-level legacy line must be removed: $legacy_line"
    fi
done
grep -Fqx '    starship init fish | source' "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish condition block must preserve the user starship line'
grep -Fqx '    zoxide init fish --cmd cd | source' "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish function block must preserve the user zoxide line'
grep -Fqx '    thefuck --alias | source' "$NIRI_FISH_CONFIG_FILE" ||
    fail 'Fish begin block must preserve the user thefuck line'
niri_bash_profile_satisfied || fail 'TTY1 Niri startup must use the managed profile block'
niri_session_entry_satisfied ||
    fail 'Niri session entry must use niri-session and avoid a bare niri launch'
niri_legacy_autostart_absent || fail 'legacy Niri user service must be removed'
grep -Fqx '// preserve niri marker' "$NIRI_CONFIG_FILE" ||
    fail 'Niri session convergence must preserve unrelated configuration'
grep -Fqx '    Mod+Return { spawn "kitty"; }' "$NIRI_BINDS_FILE" ||
    fail 'binding convergence must preserve unrelated key bindings'
grep -Fqx '# preserve profile marker' "$NIRI_BASH_PROFILE" ||
    fail 'profile convergence must preserve user content outside the managed block'
grep -Fqx '# preserve profile tail' "$NIRI_BASH_PROFILE" ||
    fail 'profile migration must preserve content after the legacy block'
if grep -Fq '# shorin:niri-session:' "$NIRI_BASH_PROFILE"; then
    fail 'legacy profile startup markers must be removed during migration'
fi
grep -Fq 'awww query' "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" ||
    fail 'QuickShell wallpaper query must use awww'
grep -Fqx 'backend = awww' "$NIRI_WAYPAPER_CONFIG_FILE" ||
    fail 'Waypaper backend migration must write awww exactly once'
grep -Fqx 'swww_transition_type = any' "$NIRI_WAYPAPER_CONFIG_FILE" ||
    fail 'Waypaper backend migration must preserve backend option names'
grep -Fqx 'property string swwwTheme: "preserve-identifier"' \
    "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" ||
    fail 'swww migration must preserve non-command identifiers'
grep -Fqx '    Mod+Alt+V hotkey-overlay-title="剪贴板 Clipboard" { spawn "niri-clip" "toggle"; }' \
    "$NIRI_BINDS_FILE" || fail 'Mod+Alt+V must invoke niri-clip toggle'
grep -Fqx '    Mod+ALT+C repeat=false hotkey-overlay-title="窗口切换 FocusShift" { spawn "focus-shift"; }' \
    "$NIRI_BINDS_FILE" || fail 'Mod+Alt+C must use the requested FocusShift binding'
[ "$(grep -Eic '^[[:space:]]*Mod\+Alt\+V[[:space:]]' "$NIRI_BINDS_FILE")" -eq 1 ] ||
    fail 'clipboard binding convergence must remove duplicates'
[ "$(wc -l < "$NIRI_VALIDATE_LOG")" -ge 1 ] ||
    fail 'Niri validation must run after managed configuration is written'
grep -Fq -- "-u $TARGET_USER -- env HOME=$HOME_DIR niri validate" \
    "$RUNUSER_VALIDATE_LOG" ||
    fail 'Niri validation must execute in the target user context'

SESSION_PROFILE_COPY="$TEST_DIR/session-profile-before-entry-audit"
SESSION_CONFIG_COPY="$TEST_DIR/session-config-before-entry-audit"
cp "$NIRI_BASH_PROFILE" "$SESSION_PROFILE_COPY"
cp "$NIRI_CONFIG_FILE" "$SESSION_CONFIG_COPY"
printf '\nexec niri\n' >> "$NIRI_BASH_PROFILE"
if niri_session_entry_satisfied; then
    fail 'a bare niri launch must fail the session entry contract'
fi
cp "$SESSION_PROFILE_COPY" "$NIRI_BASH_PROFILE"
printf '\ngraphical-session.target\n' >> "$NIRI_CONFIG_FILE"
niri_session_entry_satisfied ||
    fail 'session entry audit must remain scoped to .bash_profile'
cp "$SESSION_CONFIG_COPY" "$NIRI_CONFIG_FILE"

test_fedora_niri_session_compatibility() (
    local fedora_home="$TEST_DIR/fedora-home"
    local fedora_bin="$TEST_DIR/fedora-bin"
    local empty_path="$TEST_DIR/empty-path"
    local config_copy binds_copy arch_copy guard noise_file noise_output \
        unguarded_file lockscreen_config_noise lockscreen_binds_noise \
        saved_config_file saved_binds_file

    export SHORIN_DISTRO=fedora HOME_DIR="$fedora_home"
    unset NIRI_CONFIG_FILE NIRI_BINDS_FILE NIRI_LOCAL_BIN
    unset NIRI_LOCKSCREEN_SCRIPT_FILE NIRI_FEDORA_POLKIT_AGENT_PATH
    desktop_niri_contract_init
    mkdir -p "$HOME_DIR/.config/niri" "$HOME_DIR/.config/quickshell/scripts" \
        "$HOME_DIR/.local/bin" \
        "$fedora_bin" "$empty_path"
    printf '#!/usr/bin/env bash\n' > "$NIRI_LOCKSCREEN_SCRIPT_FILE"
    chmod 755 "$NIRI_LOCKSCREEN_SCRIPT_FILE"
    cat > "$NIRI_CONFIG_FILE" <<'EOF'
environment {
    PATH "/usr/local/bin:/usr/bin"
}
spawn-at-startup "lockscreen-wait.sh"
spawn-sh-at-startup "fd-rdd --watch-mode tiered"
spawn-at-startup "waybar"
spawn-at-startup "quickshell"
spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"
EOF
    cat > "$NIRI_BINDS_FILE" <<'EOF'
binds {
    Mod+W { spawn "vicinae" "toggle"; }
    Mod+P { spawn "waypaper" "--random"; }
    Mod+S { spawn "niriswitcherctl" "toggle"; }
    Mod+H { spawn "hyprpicker"; }
    Mod+Q { spawn-sh "hyprpicker | wl-copy"; }
    Mod+R { spawn-sh "vicinae toggle"; }
}
EOF
    chown -R "$TARGET_USER:" "$HOME_DIR"

    noise_file="$TEST_DIR/fedora-compatibility-noise.kdl"
    noise_output="$TEST_DIR/fedora-compatibility-noise.output.kdl"
    cat > "$noise_file" <<'EOF'

  // spawn-at-startup "lockscreen-wait.sh"
# polkit-gnome-authentication-agent-1
ordinary text lockscreen-wait.sh polkit-gnome-authentication-agent-1
text "spawn-at-startup \"lockscreen-wait.sh\""
EOF
    awk -v optional='fd-rdd vicinae waypaper niriswitcherctl niriswitcher waybar hyprpicker' \
        -v polkit="$NIRI_FEDORA_POLKIT_AGENT_PATH" \
        -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
        "$noise_file" > "$noise_output" ||
        fail 'Fedora compatibility AWK must process non-command text'
    cmp -s "$noise_file" "$noise_output" ||
        fail 'comments and ordinary text must remain byte-for-byte unchanged'
    niri_fedora_config_file_compatibility_satisfied "$noise_file" ||
        fail 'comments and ordinary text must not fail the Fedora compatibility contract'

    unguarded_file="$TEST_DIR/fedora-compatibility-unguarded.kdl"
    printf '%s\n' 'spawn-sh "vicinae toggle"' > "$unguarded_file"
    if niri_fedora_config_file_compatibility_satisfied "$unguarded_file"; then
        fail 'an actual unguarded optional spawn must fail the Fedora compatibility contract'
    fi

    saved_config_file=$NIRI_CONFIG_FILE
    saved_binds_file=$NIRI_BINDS_FILE
    lockscreen_config_noise="$TEST_DIR/fedora-lockscreen-noise-config.kdl"
    lockscreen_binds_noise="$TEST_DIR/fedora-lockscreen-noise-binds.kdl"
    cat > "$lockscreen_config_noise" <<'EOF'
// lockscreen.sh
description "lockscreen.sh"
spawn-at-startup "quickshell"
EOF
    cat > "$lockscreen_binds_noise" <<'EOF'
binds {
    Mod+W { spawn "kitty"; }
}
EOF
    NIRI_CONFIG_FILE=$lockscreen_config_noise
    NIRI_BINDS_FILE=$lockscreen_binds_noise
    if niri_fedora_lockscreen_contract_satisfied; then
        fail 'comments and ordinary text must not satisfy the active lockscreen contract'
    fi
    NIRI_CONFIG_FILE=$saved_config_file
    NIRI_BINDS_FILE=$saved_binds_file

    ensure_niri_fedora_session_compatibility "$TARGET_USER" ||
        fail 'Fedora Niri compatibility migration must converge'
    niri_fedora_session_compatibility_satisfied ||
        fail 'Fedora Niri compatibility contract must accept guarded commands'
    grep -Fq 'spawn-sh-at-startup "command -v' "$NIRI_CONFIG_FILE" ||
        fail 'Fedora startup commands must use shell guards'
    grep -Fq 'command -v waybar >/dev/null 2>&1' "$NIRI_CONFIG_FILE" ||
        fail 'Fedora Waybar startup must be guarded'
    grep -Fq 'command -v fd-rdd >/dev/null 2>&1' "$NIRI_CONFIG_FILE" ||
        fail 'an existing spawn-sh startup must be guarded'
    grep -Fq 'spawn-sh "command -v vicinae' "$NIRI_BINDS_FILE" ||
        fail 'Fedora binding guards must preserve original arguments'
    grep -Fq '(\"vicinae\" \"toggle\")' "$NIRI_BINDS_FILE" ||
        fail 'Fedora binding guards must retain original arguments in one shell string'
    grep -Fq 'command -v hyprpicker >/dev/null 2>&1 && (hyprpicker | wl-copy)' \
        "$NIRI_BINDS_FILE" ||
        fail 'an existing hyprpicker pipeline must be guarded inside its shell string'
    grep -Fq 'command -v vicinae >/dev/null 2>&1 && (vicinae toggle)' \
        "$NIRI_BINDS_FILE" ||
        fail 'an existing spawn-sh command must be guarded inside its shell string'
    if grep -Eq 'spawn-sh[^\n]*"sh" "-c"' "$NIRI_CONFIG_FILE" "$NIRI_BINDS_FILE"; then
        fail 'Fedora shell spawns must not emit extra KDL arguments'
    fi
    grep -Fq 'spawn-at-startup "lockscreen.sh"' "$NIRI_CONFIG_FILE" ||
        fail 'Fedora lockscreen startup must use lockscreen.sh'
    grep -Fq '/usr/libexec/kf6/polkit-kde-authentication-agent-1' \
        "$NIRI_CONFIG_FILE" ||
        fail 'Fedora polkit startup must use the KDE authentication agent'
    niri_config_valid "$TARGET_USER" ||
        fail 'Fedora migrated configuration must pass the niri validate fixture'

    if [ -n "$REAL_NIRI_BIN" ] && [ -f "$HOME/.config/niri/config.kdl" ]; then
        local real_niri_home="$TEST_DIR/real-niri-home"
        export HOME_DIR="$real_niri_home"
        mkdir -p "$HOME_DIR/.config"
        cp -a "$HOME/.config/niri" "$HOME_DIR/.config/niri"
        mkdir -p "$HOME_DIR/.config/quickshell/scripts"
        printf '#!/bin/sh\n' > "$HOME_DIR/.config/quickshell/scripts/lockscreen.sh"
        chmod 755 "$HOME_DIR/.config/quickshell/scripts/lockscreen.sh"
        NIRI_CONFIG_FILE="$HOME_DIR/.config/niri/config.kdl"
        NIRI_BINDS_FILE="$HOME_DIR/.config/niri/binds.kdl"
        NIRI_LOCKSCREEN_SCRIPT_FILE="$HOME_DIR/.config/quickshell/scripts/lockscreen.sh"
        export NIRI_CONFIG_FILE NIRI_BINDS_FILE NIRI_LOCKSCREEN_SCRIPT_FILE
        chown -R "$TARGET_USER:" "$HOME_DIR"
        ensure_niri_fedora_session_compatibility "$TARGET_USER" ||
            fail 'the real Niri fixture must converge before validation'
        XDG_CONFIG_HOME="$HOME_DIR/.config" "$REAL_NIRI_BIN" validate \
            -c "$NIRI_CONFIG_FILE" ||
            fail 'the real Niri validator must accept the Fedora migration'
    fi

    config_copy="$TEST_DIR/fedora-config-before-idempotent.kdl"
    binds_copy="$TEST_DIR/fedora-binds-before-idempotent.kdl"
    cp "$NIRI_CONFIG_FILE" "$config_copy"
    cp "$NIRI_BINDS_FILE" "$binds_copy"
    ensure_niri_fedora_session_compatibility "$TARGET_USER" ||
        fail 'a second Fedora compatibility run must succeed'
    cmp -s "$config_copy" "$NIRI_CONFIG_FILE" ||
        fail 'Fedora config migration must be content-idempotent'
    cmp -s "$binds_copy" "$NIRI_BINDS_FILE" ||
        fail 'Fedora binding migration must be content-idempotent'

    guard=$(niri_optional_command_guard_contract vicinae)
    if env -i PATH="$empty_path" HOME="$HOME_DIR" /usr/bin/bash \
        -c "$guard" sh toggle; then
        fail 'an absent optional command must make its shell guard skip'
    fi
    cat > "$fedora_bin/vicinae" <<'EOF'
#!/bin/sh
[ "$1" = toggle ]
EOF
    chmod 755 "$fedora_bin/vicinae"
    env -i PATH="$fedora_bin" HOME="$HOME_DIR" /usr/bin/bash \
        -c "$guard" sh toggle ||
        fail 'an installed optional command must run through its shell guard'

    printf '%s\n' 'arch legacy configuration' > "$NIRI_CONFIG_FILE"
    printf '%s\n' 'arch legacy bindings' > "$NIRI_BINDS_FILE"
    arch_copy="$TEST_DIR/arch-config-before-noop.kdl"
    cp "$NIRI_CONFIG_FILE" "$arch_copy"
    export SHORIN_DISTRO=arch
    ensure_niri_fedora_session_compatibility "$TARGET_USER" ||
        fail 'Fedora compatibility helper must be a no-op on Arch'
    cmp -s "$arch_copy" "$NIRI_CONFIG_FILE" ||
        fail 'Arch config must remain unchanged by Fedora migration'

    export SHORIN_DISTRO=fedora
    cat > "$NIRI_CONFIG_FILE" <<'EOF'
spawn-at-startup "lockscreen-wait.sh"
spawn-at-startup "waybar"
EOF
    cat > "$NIRI_BINDS_FILE" <<'EOF'
binds {
    Mod+W { spawn "vicinae" "toggle"; }
}
EOF
    cp "$NIRI_CONFIG_FILE" "$config_copy"
    cp "$NIRI_BINDS_FILE" "$binds_copy"
    ensure_niri_quickshell_startup() { :; }
    ensure_niri_optional_startup() { :; }
    ensure_niri_fcitx5_startup() { :; }
    ensure_niri_path() { :; }
    ensure_niri_wallpaper_backend() { :; }
    niri_config_valid() { return 1; }
    if ensure_niri_managed_config_files "$TARGET_USER"; then
        fail 'a validation failure must reject Fedora config migration'
    fi
    cmp -s "$config_copy" "$NIRI_CONFIG_FILE" ||
        fail 'a failed Fedora migration must restore config.kdl'
    cmp -s "$binds_copy" "$NIRI_BINDS_FILE" ||
        fail 'a failed Fedora migration must restore binds.kdl'
)

test_fedora_niri_session_compatibility
export SHORIN_DISTRO=arch

# The Fedora compatibility transform must be a no-op for a complete Arch
# deployment; preserve upstream source bytes rather than applying Fedora-only
# substitutions on Arch.
ARCH_WALLPAPER_TREE="$TEST_DIR/arch-wallpaper-tree"
mkdir -p "$ARCH_WALLPAPER_TREE/quickshell/lockscreen"
printf '%s\n' 'command: ["sh", "-c", "swww query"]' \
    > "$ARCH_WALLPAPER_TREE/quickshell/lockscreen/shell.qml"
ARCH_WALLPAPER_COPY="$TEST_DIR/arch-wallpaper-copy.qml"
cp "$ARCH_WALLPAPER_TREE/quickshell/lockscreen/shell.qml" \
    "$ARCH_WALLPAPER_COPY"
niri_transform_wallpaper_tree "$ARCH_WALLPAPER_TREE" ||
    fail 'Arch wallpaper deployment must keep the Fedora transform disabled'
cmp -s "$ARCH_WALLPAPER_COPY" \
    "$ARCH_WALLPAPER_TREE/quickshell/lockscreen/shell.qml" ||
    fail 'Arch wallpaper deployment must preserve upstream source bytes'

printf 'set -gx USER_CUSTOM_ENV preserved\n' > "$NIRI_FISH_RUSTUP_FILE"
FISH_CUSTOM_COPY="$TEST_DIR/custom-rustup.fish"
cp "$NIRI_FISH_RUSTUP_FILE" "$FISH_CUSTOM_COPY"
ensure_niri_fish_sources "$TARGET_USER"
cmp -s "$NIRI_FISH_RUSTUP_FILE" "$FISH_CUSTOM_COPY" ||
    fail 'custom legacy Fish files are user-owned and must not be overwritten'
niri_fish_sources_satisfied ||
    fail 'custom legacy Fish files must coexist with the managed guard contract'

FISH_LINK_TARGET="$TEST_DIR/user-rustup-target.fish"
printf 'source "$HOME/.cargo/env.fish"\n' > "$FISH_LINK_TARGET"
rm -f "$NIRI_FISH_RUSTUP_FILE"
ln -s "$FISH_LINK_TARGET" "$NIRI_FISH_RUSTUP_FILE"
ensure_niri_fish_sources "$TARGET_USER"
[ -L "$NIRI_FISH_RUSTUP_FILE" ] &&
    [ "$(readlink "$NIRI_FISH_RUSTUP_FILE")" = "$FISH_LINK_TARGET" ] ||
    fail 'legacy Fish symlinks are user-owned and must never be deleted'
niri_fish_sources_satisfied ||
    fail 'a user-owned legacy Fish symlink must satisfy the migration boundary'

# A preserved user-owned symlink is outside the migration boundary. If it
# points at a missing generated file, the Fish login contract must fail rather
# than hide the startup error; remove the fixture before the remaining session
# convergence checks.
if niri_fish_login_satisfied; then
    fail 'a broken user-owned Fish symlink must not satisfy the zero-stderr contract'
fi
rm -f "$NIRI_FISH_RUSTUP_FILE"

# A previously deployed tty1 block without -l loops through the login shell;
# it must drift and be upgraded in place.
cat > "$NIRI_BASH_PROFILE" <<'EOF'
# preserve upgrade marker
# >>> shorin niri tty1 >>>
if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then
    exec niri-session
fi
# <<< shorin niri tty1 <<<
EOF
if niri_bash_profile_satisfied; then
    fail 'a tty1 startup block without -l must drift'
fi
ensure_niri_bash_profile "$TARGET_USER"
niri_bash_profile_satisfied ||
    fail 'the upgraded tty1 startup block must satisfy the contract'
grep -Fqx '    exec niri-session -l' "$NIRI_BASH_PROFILE" ||
    fail 'tty1 startup must run niri-session -l inside the login shell'
[ "$(grep -Fc 'exec niri-session' "$NIRI_BASH_PROFILE")" -eq 1 ] ||
    fail 'the tty1 startup upgrade must not duplicate the exec line'
grep -Fqx '# preserve upgrade marker' "$NIRI_BASH_PROFILE" ||
    fail 'the tty1 startup upgrade must preserve user content'

chmod 000 "$NIRI_BINDS_FILE"
if niri_session_files_accessible "$TARGET_USER"; then
    fail 'unreadable Niri session files must fail the access contract'
fi
ensure_niri_session_config "$TARGET_USER"
niri_session_files_accessible "$TARGET_USER" ||
    fail 'session apply must repair target-user ownership and readability'

SESSION_COPY_DIR="$TEST_DIR/session-copy"
mkdir -p "$SESSION_COPY_DIR"
cp "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/config.kdl"
cp "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/binds.kdl"
cp "$NIRI_BASH_PROFILE" "$SESSION_COPY_DIR/bash_profile"
cp "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" "$SESSION_COPY_DIR/shell.qml"
ensure_niri_session_config "$TARGET_USER"
cmp -s "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/config.kdl" &&
    cmp -s "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/binds.kdl" &&
    cmp -s "$NIRI_BASH_PROFILE" "$SESSION_COPY_DIR/bash_profile" &&
    cmp -s "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
        "$SESSION_COPY_DIR/shell.qml" ||
    fail 'desktop session convergence must be content-idempotent'

printf '\nspawn-at-startup "swww-daemon"\n' >> "$NIRI_CONFIG_FILE"
printf '\nrollbackCommand: ["sh", "-c", "swww query"]\n' \
    >> "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml"
sed -i 's/Mod+Alt+C repeat=false.*/Mod+Alt+C { spawn "old-switcher"; }/' \
    "$NIRI_BINDS_FILE"
cp "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/rollback-config.kdl"
cp "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/rollback-binds.kdl"
cp "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
    "$SESSION_COPY_DIR/rollback-shell.qml"
cp "$NIRI_WAYPAPER_CONFIG_FILE" "$SESSION_COPY_DIR/rollback-waypaper.ini"
cp "$NIRI_FISH_CONFIG_FILE" "$SESSION_COPY_DIR/rollback-fish-config.fish"
cp "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" \
    "$SESSION_COPY_DIR/rollback-quickshell-source"
NIRI_VALIDATE_FAIL=1
export NIRI_VALIDATE_FAIL
if ensure_niri_session_config "$TARGET_USER"; then
    fail 'failed Niri validation must reject the attempted convergence'
fi
cmp -s "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/rollback-config.kdl" &&
    cmp -s "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/rollback-binds.kdl" &&
cmp -s "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
    "$SESSION_COPY_DIR/rollback-shell.qml" ||
    fail 'failed validation must atomically restore Niri and QuickShell files'
cmp -s "$NIRI_WAYPAPER_CONFIG_FILE" \
    "$SESSION_COPY_DIR/rollback-waypaper.ini" ||
    fail 'failed validation must atomically restore Waypaper configuration'
cmp -s "$NIRI_FISH_CONFIG_FILE" \
    "$SESSION_COPY_DIR/rollback-fish-config.fish" ||
    fail 'failed validation must atomically restore Fish configuration'
cmp -s "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" \
    "$SESSION_COPY_DIR/rollback-quickshell-source" ||
    fail 'failed validation must atomically restore QuickShell source state'
NIRI_VALIDATE_FAIL=0
export NIRI_VALIDATE_FAIL
niri_quickshell_stage_and_deploy "$DOTFILES_CHECKOUT" "$TARGET_USER" ||
    fail 'source redeployment must repair the QuickShell tree before session apply'
ensure_niri_session_config "$TARGET_USER"
unset SHORIN_FORCE_RUNUSER
unset -f runuser

AUTOLOGIN_SYSTEMCTL_LOG="$TEST_DIR/autologin-systemctl.log"
MOCK_DM=0
pacman() {
    [ "$1" = -Q ] && [ "$2" = gdm ] && [ "$MOCK_DM" -eq 1 ]
}
systemctl() {
    printf '%s\n' "$*" >> "$AUTOLOGIN_SYSTEMCTL_LOG"
}
mkdir -p "$(dirname "$NIRI_AUTOLOGIN_FILE")"
niri_autologin_contract "$TARGET_USER" > "$NIRI_AUTOLOGIN_FILE"
niri_autologin_state_satisfied ||
    fail 'managed target-user autologin must satisfy a display-manager-free system'
MOCK_DM=1
if niri_autologin_state_satisfied; then
    fail 'managed TTY autologin must drift when a display manager is installed'
fi
ensure_niri_autologin_state "$TARGET_USER" true
[ ! -e "$NIRI_AUTOLOGIN_FILE" ] ||
    fail 'skip mode must remove an exact installer-managed autologin override'
grep -Fqx 'daemon-reload' "$AUTOLOGIN_SYSTEMCTL_LOG" ||
    fail 'autologin override removal must reload the system manager'

printf '[Service]\n# user-owned getty customization\n' > "$NIRI_AUTOLOGIN_FILE"
AUTOLOGIN_CUSTOM_COPY="$TEST_DIR/custom-autologin.conf"
cp "$NIRI_AUTOLOGIN_FILE" "$AUTOLOGIN_CUSTOM_COPY"
ensure_niri_autologin_state "$TARGET_USER" false
cmp -s "$NIRI_AUTOLOGIN_FILE" "$AUTOLOGIN_CUSTOM_COPY" ||
    fail 'enable mode must preserve a non-managed custom getty override'
ensure_niri_autologin_state "$TARGET_USER" true
cmp -s "$NIRI_AUTOLOGIN_FILE" "$AUTOLOGIN_CUSTOM_COPY" ||
    fail 'skip mode must preserve a non-managed custom getty override'
unset -f pacman systemctl

niri_firefox_policy_matches || fail 'Firefox policy must have an exact contract'
niri_nautilus_override_matches || fail 'Nautilus user override must match its source contract'
niri_user_terminal_link_matches || fail 'terminal compatibility must use an exact user link'
niri_portal_config_matches || fail 'portal selection must have an exact contract'
niri_gtk_links_match || fail 'GTK links must target the managed user theme'
grep -Fqx 'DBusActivatable=false' "$NIRI_NAUTILUS_OVERRIDE_FILE" ||
    fail 'Nautilus override must disable D-Bus activation for its Exec environment'
grep -Fqx 'Exec=env GTK_IM_MODULE=fcitx nautilus --new-window %U' \
    "$NIRI_NAUTILUS_OVERRIDE_FILE" ||
    fail 'Nautilus override must add input environment without changing the vendor file'
grep -Fqx 'DBusActivatable=true' "$NIRI_NAUTILUS_VENDOR_FILE" ||
    fail 'the vendor Nautilus desktop file must remain untouched'

APPLY_SCRIPT="$ROOT_DIR/scripts/modules/desktop-niri/apply.sh"
if grep -Eq '/usr/bin/gnome-terminal|sed[[:space:]]+-i.*Nautilus' "$APPLY_SCRIPT"; then
    fail 'desktop apply must not modify package-owned executable or desktop files'
fi
if grep -Fq 'NOPASSWD: ALL' "$APPLY_SCRIPT"; then
    fail 'desktop apply must not grant broad temporary sudo privileges'
fi
if grep -Fq 'niri-autostart.service' "$APPLY_SCRIPT"; then
    fail 'desktop apply must not recreate the retired Niri user service'
fi

PROFILE_DIR="$TEST_DIR/profile"
BIN_DIR="$TEST_DIR/mock-bin"
PACKAGE_SOURCES="$TEST_DIR/package-sources"
mkdir -p "$PROFILE_DIR" "$BIN_DIR" "$PACKAGE_SOURCES"
mkdir -p "$HOME_DIR/Pictures/Wallpapers" "$HOME_DIR/Templates"
printf 'wallpaper\n' > "$NIRI_DEFAULT_WALLPAPER_FILE"
touch "$HOME_DIR/Templates/new"
printf '#!/usr/bin/env bash\n' > "$HOME_DIR/Templates/new.sh"
niri_wallpapers_deployed ||
    fail 'the deployed default wallpaper must satisfy the wallpaper state'
niri_starship_config_deployed ||
    fail 'the deployed Starship configuration must satisfy the desktop state'
niri_templates_deployed ||
    fail 'deployed template files must satisfy the template state'

printf 'imv\n' > "$PROFILE_DIR/niri-packages.list"
for package in nautilus-open-any-terminal swaylock-effects; do
    printf 'source=aur\nversion=1.0\n' > "$PACKAGE_SOURCES/$package"
done
cat > "$BIN_DIR/pacman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -Q ] && { [ "$2" = ddcutil ] || [ "$2" = swayosd ]; }; then
    exit 1
fi
if [ "$1" = -Q ]; then
    printf '%s 1.0\n' "$2"
    exit 0
fi
exit 1
EOF
chmod +x "$BIN_DIR/pacman"

status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'complete desktop managed state must check successfully'

# Read-only desktop inspection must not rewrite managed files or execute any
# user startup shell.  The fixture is complete, so check should be clean.
CHECK_NO_SIDE_EFFECT_COPY="$TEST_DIR/check-no-side-effects"
mkdir -p "$CHECK_NO_SIDE_EFFECT_COPY"
cp "$NIRI_FISH_CONFIG_FILE" "$CHECK_NO_SIDE_EFFECT_COPY/fish-config"
cp "$NIRI_WAYPAPER_CONFIG_FILE" "$CHECK_NO_SIDE_EFFECT_COPY/waypaper"
cp "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$CHECK_NO_SIDE_EFFECT_COPY/quickshell-state"
status=0
PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check >/dev/null 2>&1 ||
    status=$?
[ "$status" -eq 0 ] || fail 'desktop check must accept a complete fixture'
cmp -s "$CHECK_NO_SIDE_EFFECT_COPY/fish-config" "$NIRI_FISH_CONFIG_FILE" ||
    fail 'desktop check must not rewrite Fish config'
cmp -s "$CHECK_NO_SIDE_EFFECT_COPY/waypaper" "$NIRI_WAYPAPER_CONFIG_FILE" ||
    fail 'desktop check must not rewrite Waypaper config'
cmp -s "$CHECK_NO_SIDE_EFFECT_COPY/quickshell-state" \
    "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ||
    fail 'desktop check must not rewrite QuickShell source state'

mv "$NIRI_STARSHIP_CONFIG_FILE" "$NIRI_STARSHIP_CONFIG_FILE.missing"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] || fail 'a missing Starship config must report desktop drift'
grep -Fq file:starship-config <<< "$output" ||
    fail 'desktop check must identify a missing Starship configuration'
mv "$NIRI_STARSHIP_CONFIG_FILE.missing" "$NIRI_STARSHIP_CONFIG_FILE"

cat >> "$NIRI_MATUGEN_CONFIG_FILE" <<'EOF'

[templates.starship]
input_path = '~/.config/matugen/templates/starship-colors.toml'
output_path = '~/.config/starship.toml'
EOF
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] ||
    fail 'active Matugen Starship output must report desktop drift'
grep -Fq config:matugen-starship-output <<< "$output" ||
    fail 'desktop check must identify Matugen Starship output drift'
disable_matugen_starship_output
printf 'retired template\n' > "$NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] ||
    fail 'a retired Matugen Starship template must report desktop drift'
grep -Fq legacy:matugen-starship-template-absent <<< "$output" ||
    fail 'desktop check must identify the retired Matugen Starship template'
disable_matugen_starship_output

printf 'unrelated wallpaper\n' > "$NIRI_WALLPAPER_DIR/unrelated.png"
mv "$NIRI_DEFAULT_WALLPAPER_FILE" "$NIRI_DEFAULT_WALLPAPER_FILE.missing"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] || fail 'a missing default wallpaper must report desktop drift'
grep -Fq file:wallpapers <<< "$output" ||
    fail 'desktop check must identify a missing default wallpaper'
mv "$NIRI_DEFAULT_WALLPAPER_FILE.missing" "$NIRI_DEFAULT_WALLPAPER_FILE"

printf 'stale policy\n' > "$NIRI_FIREFOX_POLICY_FILE"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'stale managed desktop state must fail verification'
grep -Fq file:firefox-policy <<< "$output" ||
    fail 'desktop verification must identify the stale managed target'
niri_firefox_policy_contract > "$NIRI_FIREFOX_POLICY_FILE"

printf '[Service]\nExecStart=/usr/bin/niri-session\n' > "$NIRI_LEGACY_UNIT"
ln -s ../niri-autostart.service "$NIRI_LEGACY_UNIT_LINK"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] || fail 'legacy Niri autostart service must report drift'
grep -Fq legacy:niri-autostart-absent <<< "$output" ||
    fail 'legacy Niri service drift must identify the migration target'
RUNUSER_LOG="$TEST_DIR/runuser.log"
LEGACY_ACTIVE_STATUS=2
LEGACY_ENABLED_STATUS=1
LEGACY_DISABLE_FAIL=1
niri_user_bus_is_available() {
    return 0
}
runuser() {
    printf '%s\n' "$*" >> "$RUNUSER_LOG"
    case "$*" in
        *'systemctl --user is-active --quiet niri-autostart.service'*)
            return "$LEGACY_ACTIVE_STATUS"
            ;;
        *'systemctl --user is-enabled --quiet niri-autostart.service'*)
            return "$LEGACY_ENABLED_STATUS"
            ;;
        *'systemctl --user disable --now niri-autostart.service'*)
            [ "$LEGACY_DISABLE_FAIL" -eq 0 ]
            ;;
        *) return 0 ;;
    esac
}
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'a user-bus activity query error must fail convergence'
fi
[ -e "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'a user-bus query error must preserve legacy unit files'
LEGACY_ACTIVE_STATUS=3
LEGACY_ENABLED_STATUS=2
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'a user-bus enabled query error must fail convergence'
fi
[ -e "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'an enabled-state query error must preserve legacy unit files'
LEGACY_ACTIVE_STATUS=0
LEGACY_ENABLED_STATUS=1
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'an active legacy unit that cannot be disabled must fail convergence'
fi
[ -e "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'failed legacy unit shutdown must preserve its files for recovery'
LEGACY_DISABLE_FAIL=0
ensure_niri_bash_profile "$TARGET_USER"
niri_legacy_autostart_absent || fail 'profile convergence must remove legacy service artifacts'
grep -Fq 'systemctl --user disable --now niri-autostart.service' "$RUNUSER_LOG" ||
    fail 'an active legacy unit must be disabled before its files are removed'
grep -Fq 'systemctl --user daemon-reload' "$RUNUSER_LOG" ||
    fail 'legacy service removal must reload an available user manager'
grep -Fq 'systemctl --user reset-failed niri-autostart.service' "$RUNUSER_LOG" ||
    fail 'legacy service removal must clear its loaded failure state'
DISABLE_LINE=$(grep -n 'systemctl --user disable --now niri-autostart.service' \
    "$RUNUSER_LOG" | tail -1 | cut -d: -f1)
RELOAD_LINE=$(grep -n 'systemctl --user daemon-reload' "$RUNUSER_LOG" |
    tail -1 | cut -d: -f1)
[ "$DISABLE_LINE" -lt "$RELOAD_LINE" ] ||
    fail 'legacy unit disable must happen before user-manager reload'
unset -f runuser
niri_user_bus_is_available() {
    return 1
}

printf 'PASS: desktop-niri desired-state contract\n'
