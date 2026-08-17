#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# This test intentionally performs the pinned upstream downloads.  The normal
# fixture suite remains offline; opt in with SHORIN_REAL_ARTIFACTS=1.
if [ "${SHORIN_REAL_ARTIFACTS:-0}" != 1 ]; then
    printf 'SKIP: Fedora provider real-artifact test (set SHORIN_REAL_ARTIFACTS=1)\n'
    exit 0
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shorin-fedora-real.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
export TARGET_USER=${TARGET_USER:-$(id -un)}
export HOME_DIR="$TEST_DIR/home"
[ -n "$TARGET_USER" ] || fail 'unable to resolve the target user'
[ "$(id -u "$TARGET_USER")" -eq "$(id -u)" ] ||
    fail 'real-artifact E2E requires the target user to be the invoking user'
[ -d "$HOME_DIR" ] || mkdir -p "$HOME_DIR"
[ "$(stat -c '%u' "$HOME_DIR")" -eq "$(id -u)" ] ||
    fail 'temporary target home is not owned by the invoking user'
[ -n "$HOME_DIR" ] || fail 'unable to resolve the target user home'

source "$ROOT_DIR/scripts/lib/core.sh"

for command_name in curl sha256sum tar unzip xz fc-query fc-scan; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "required real-artifact command is missing: $command_name"
done
[ "$(fedora_provider_architecture)" = x86_64 ] ||
    fail 'the fixed provider assets are only supported on x86_64'

work="$TEST_DIR/work"
mkdir -p "$work"

download_verified() {
    local url=$1 digest=$2 output=$3

    printf 'DOWNLOAD: %s\n' "$url"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$url" -o "$output"
    printf '%s  %s\n' "$digest" "$output" | sha256sum -c - >/dev/null
}

verify_family() {
    local file=$1 family=$2 query scan

    query=$(fc-query -f '%{family}\n' "$file") || return 1
    scan=$(fc-scan -f '%{family}\n' "$file") || return 1
    fedora_font_family_list_contains "$family" "$query" || return 1
    fedora_font_family_list_contains "$family" "$scan" || return 1
    printf 'FONT: %s -> %s\n' "$(basename "$file")" "$family"
}

verify_mdi_glyphs() {
    local file=$1 charset glyph query_charset scan_charset

    query_charset=$(fc-query -f '%{charset}\n' "$file") || return 1
    scan_charset=$(fc-scan -f '%{charset}\n' "$file") || return 1
    for glyph in $FEDORA_MDI_GLYPHS; do
        fedora_font_charset_contains "$query_charset" "$glyph" || return 1
        fedora_font_charset_contains "$scan_charset" "$glyph" || return 1
        printf 'GLYPH: U+%s\n' "${glyph^^}"
    done
}

verify_target_user_contracts() {
    local font_dir=$HOME_DIR/.local/share/fonts/shorin file owner mode

    fedora_starship_target_satisfied "$TARGET_USER" "$HOME_DIR" ||
        fail 'temporary HOME Starship contract did not converge'
    for provider_target in ttf-jetbrains-mono-nerd \
        ttf-jetbrains-maple-mono-nf-xx-xx material-design-icons; do
        fedora_font_target_satisfied "$provider_target" "$TARGET_USER" \
            "$HOME_DIR" || fail "temporary HOME font contract did not converge: $provider_target"
    done
    [ "$(stat -c '%u:%g:%a' "$HOME_DIR/.local/bin/starship")" = \
        "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER"):755" ] ||
        fail 'temporary HOME Starship owner/mode contract failed'
    [ -d "$font_dir" ] && [ "$(stat -c '%u:%g:%a' "$font_dir")" = \
        "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER"):755" ] ||
        fail 'temporary HOME font directory owner/mode contract failed'
    while IFS= read -r -d '' file; do
        owner=$(stat -c '%u:%g' "$file")
        mode=$(stat -c '%a' "$file")
        [ "$owner" = "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" ] ||
            fail "temporary HOME font owner contract failed: $file"
        [ "$mode" = 644 ] || fail "temporary HOME font mode contract failed: $file"
    done < <(find "$font_dir" -type f -print0)
    PATH="$HOME_DIR/.local/bin:$PATH" command -v starship | grep -Fqx \
        "$HOME_DIR/.local/bin/starship" || fail 'temporary HOME PATH did not resolve provider Starship'
    HOME="$HOME_DIR" XDG_DATA_HOME="$HOME_DIR/.local/share" \
        PATH="$HOME_DIR/.local/bin:$PATH" starship --version >/dev/null ||
        fail 'temporary HOME Starship command did not execute'
    [ -d "$TEST_DIR/cache" ] || fail 'fontconfig cache directory was not created'
}

for provider_target in ttf-jetbrains-mono-nerd \
    ttf-jetbrains-maple-mono-nf-xx-xx material-design-icons; do
    fedora_font_source_contract_valid "$provider_target" ||
        fail "production source contract is not fixed: $provider_target"
done
fedora_starship_source_contract_valid ||
    fail 'production Starship source contract is not fixed'

starship_archive="$work/starship.tar.gz"
download_verified "$FEDORA_STARSHIP_URL" "$FEDORA_STARSHIP_SHA256" \
    "$starship_archive" || fail 'Starship download or SHA-256 verification failed'
fedora_starship_archive_entries_safe "$starship_archive" ||
    fail 'Starship archive safety contract rejected the official archive'
starship_extract="$work/starship"
mkdir -p "$starship_extract"
tar --extract --gzip --file "$starship_archive" --directory "$starship_extract" \
    --no-same-owner --no-same-permissions
[ -f "$starship_extract/starship" ] &&
    [ ! -L "$starship_extract/starship" ] &&
    [ -x "$starship_extract/starship" ] ||
    fail 'official Starship archive did not contain a regular executable'
printf 'COMMAND: starship archive entry is regular and executable\n'

nerd_archive="$work/JetBrainsMono.tar.xz"
download_verified "$FEDORA_JETBRAINSMONO_NERD_URL" \
    "$FEDORA_JETBRAINSMONO_NERD_SHA256" "$nerd_archive" ||
    fail 'Nerd Font download or SHA-256 verification failed'
fedora_font_archive_entries_safe "$nerd_archive" nerd ||
    fail 'Nerd Font archive safety contract rejected the official archive'
nerd_extract="$work/nerd"
mkdir -p "$nerd_extract"
tar --extract --xz --file "$nerd_archive" --directory "$nerd_extract" \
    --no-same-owner --no-same-permissions
if find "$nerd_extract" -type l -print -quit | grep -q .; then
    fail 'official Nerd Font archive extracted a symlink'
fi
nerd_file=$(find "$nerd_extract" -type f -name 'JetBrainsMonoNerdFont-*.ttf' \
    -print -quit)
[ -n "$nerd_file" ] || fail 'official Nerd Font archive has no whitelisted TTF'
fedora_nerd_font_file_name_allowed "$nerd_file" ||
    fail 'official Nerd Font TTF is outside the whitelist'
verify_family "$nerd_file" "$FEDORA_NERD_FONT_FAMILY" ||
    fail 'official Nerd Font exact family verification failed'

maple_archive="$work/JetBrainsMapleMono.zip"
download_verified "$FEDORA_JETBRAINS_MAPLE_URL" \
    "$FEDORA_JETBRAINS_MAPLE_SHA256" "$maple_archive" ||
    fail 'Fusion Maple download or SHA-256 verification failed'
fedora_font_archive_entries_safe "$maple_archive" maple ||
    fail 'Fusion Maple archive path safety contract rejected the official archive'
fedora_zip_archive_types_safe "$maple_archive" ||
    fail 'Fusion Maple archive type safety contract rejected the official archive'
maple_extract="$work/maple"
mkdir -p "$maple_extract"
unzip -q "$maple_archive" -d "$maple_extract"
if find "$maple_extract" -type l -print -quit | grep -q .; then
    fail 'Fusion Maple archive extracted a symlink'
fi
maple_file=$(find "$maple_extract" -type f -name '*.ttf' -print -quit)
[ -n "$maple_file" ] || fail 'Fusion Maple archive has no TTF'
fedora_maple_font_file_name_allowed "$maple_file" ||
    fail 'Fusion Maple TTF is outside the whitelist'
verify_family "$maple_file" "$FEDORA_MAPLE_FONT_FAMILY" ||
    fail 'Fusion Maple exact family verification failed'

mdi_file="$work/materialdesignicons-webfont.ttf"
download_verified "$FEDORA_MATERIAL_DESIGN_ICONS_URL" \
    "$FEDORA_MATERIAL_DESIGN_ICONS_SHA256" "$mdi_file" ||
    fail 'Material Design Icons download or SHA-256 verification failed'
fedora_mdi_font_file_name_allowed "$mdi_file" ||
    fail 'Material Design Icons filename contract failed'
verify_family "$mdi_file" "$FEDORA_MDI_FONT_FAMILY" ||
    fail 'Material Design Icons exact family verification failed'
verify_mdi_glyphs "$mdi_file" ||
    fail 'Material Design Icons required glyph verification failed'

# Run the providers against a completely isolated temporary HOME.  The
# archives above were downloaded from the fixed production URLs; this curl
# fixture only avoids downloading the same 150+ MiB Maple release twice.
KITTY_CONFIG="$HOME_DIR/.config/kitty/kitty.conf"
mkdir -p "$(dirname "$KITTY_CONFIG")"
printf 'font_family JetBrains Maple Mono\n' > "$KITTY_CONFIG"
FONTCONFIG_FILE="$TEST_DIR/fonts.conf"
export FONTCONFIG_FILE
cat > "$FONTCONFIG_FILE" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$HOME_DIR/.local/share/fonts</dir>
  <dir>$TEST_DIR/rollback-home/.local/share/fonts</dir>
  <cachedir>$TEST_DIR/cache</cachedir>
</fontconfig>
EOF

# The host used for this test may already provide a system Starship.  Shadow
# it with an intentionally unusable command so the temporary HOME exercises
# the provider install path instead of accepting the host command.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/starship" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$TEST_DIR/bin/starship"
export PATH="$TEST_DIR/bin:$PATH"

curl() {
    local url='' output=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then
            output=$2
            shift 2
        else
            url=$1
            shift
        fi
    done
    case "$url" in
        "$FEDORA_STARSHIP_URL") cp "$starship_archive" "$output" ;;
        "$FEDORA_JETBRAINSMONO_NERD_URL") cp "$nerd_archive" "$output" ;;
        "$FEDORA_JETBRAINS_MAPLE_URL") cp "$maple_archive" "$output" ;;
        "$FEDORA_MATERIAL_DESIGN_ICONS_URL") cp "$mdi_file" "$output" ;;
        *) return 1 ;;
    esac
}

fedora_install_desktop_providers "$TARGET_USER" "$HOME_DIR" ||
    fail 'temporary HOME provider installation failed'
verify_target_user_contracts
fc_match_nerd=$(fc-match -f '%{family}\n' "$FEDORA_NERD_FONT_FAMILY")
fedora_font_family_list_contains "$FEDORA_NERD_FONT_FAMILY" "$fc_match_nerd" ||
    fail 'temporary HOME fc-match did not return exact Nerd Font family'
fc_match_maple=$(fc-match -f '%{family}\n' "$FEDORA_MAPLE_FONT_FAMILY")
fedora_font_family_list_contains "$FEDORA_MAPLE_FONT_FAMILY" "$fc_match_maple" ||
    fail 'temporary HOME fc-match did not return exact Maple family'
fc_match_mdi=$(fc-match -f '%{family}\n' "$FEDORA_MDI_FONT_FAMILY")
fedora_font_family_list_contains "$FEDORA_MDI_FONT_FAMILY" "$fc_match_mdi" ||
    fail 'temporary HOME fc-match did not return exact MDI family'

# A later provider failure must remove only this transaction's Starship
# output.  Existing user files are not present in this fresh HOME.
ROLLBACK_HOME="$TEST_DIR/rollback-home"
mkdir -p "$ROLLBACK_HOME/.config/kitty"
printf 'font_family JetBrains Maple Mono\n' > "$ROLLBACK_HOME/.config/kitty/kitty.conf"
_fedora_install_desktop_font_provider_unlocked() { return 1; }
status=0
fedora_install_desktop_providers "$TARGET_USER" "$ROLLBACK_HOME" || status=$?
[ "$status" -ne 0 ] || fail 'simulated later provider failure unexpectedly succeeded'
[ ! -e "$ROLLBACK_HOME/.local/bin/starship" ] ||
    fail 'transaction rollback left Starship after later provider failure'
[ ! -e "$ROLLBACK_HOME/.local/share/fonts/shorin" ] ||
    fail 'transaction rollback left a new font directory after later provider failure'

printf 'PASS: Fedora provider real artifacts (fixed SHA/archive/fc contracts and temporary HOME E2E)\n'
