#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
HOME_DIR="$TEST_DIR/home"
ASSET_DIR="$TEST_DIR/assets"
CALLS="$TEST_DIR/calls"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$ASSET_DIR/nerd" "$ASSET_DIR/maple"
mkdir -p "$HOME_DIR/.config/kitty"
printf 'font_family JetBrains Maple Mono\n' > "$HOME_DIR/.config/kitty/kitty.conf"
: > "$CALLS"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

link_tool() {
    ln -s "$(type -P "$1")" "$BIN_DIR/$1"
}

for tool in bash env tar gzip xz sha256sum unzip curl install id find mv rm mkdir dirname ln uname flock \
    basename mktemp grep awk sed rmdir cp cat wc sort chmod stat; do
    link_tool "$tool"
done

printf '#!/usr/bin/env bash\nprintf "starship 1.26.0\\n"\n' > \
    "$ASSET_DIR/starship"
chmod 755 "$ASSET_DIR/starship"
mkdir -p "$ASSET_DIR/starship-root"
cp "$ASSET_DIR/starship" "$ASSET_DIR/starship-root/starship"
tar -czf "$ASSET_DIR/starship.tar.gz" -C "$ASSET_DIR/starship-root" starship

printf 'nerd\n' > "$ASSET_DIR/nerd/JetBrainsMonoNerdFont-Regular.ttf"
tar -cJf "$ASSET_DIR/nerd.tar.xz" -C "$ASSET_DIR/nerd" \
    JetBrainsMonoNerdFont-Regular.ttf
printf 'maple\n' > "$ASSET_DIR/maple/JetBrainsMapleMono-NF-Regular.ttf"
(cd "$ASSET_DIR/maple" && zip -q "$ASSET_DIR/maple.zip" \
    JetBrainsMapleMono-NF-Regular.ttf)
printf 'mdi\n' > "$ASSET_DIR/mdi.ttf"

STARSHIP_SHA=$(sha256sum "$ASSET_DIR/starship.tar.gz" | awk '{print $1}')
NERD_SHA=$(sha256sum "$ASSET_DIR/nerd.tar.xz" | awk '{print $1}')
MAPLE_SHA=$(sha256sum "$ASSET_DIR/maple.zip" | awk '{print $1}')
MDI_SHA=$(sha256sum "$ASSET_DIR/mdi.ttf" | awk '{print $1}')

export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
export TARGET_USER=$(id -un) HOME_DIR
source "$ROOT_DIR/scripts/lib/core.sh"
PATH="$BIN_DIR"; export PATH

if ! env \
    FEDORA_STARSHIP_URL=https://evil.example/starship.tar.gz \
    FEDORA_STARSHIP_SHA256=$(printf '%064d' 0) \
    FEDORA_JETBRAINS_MAPLE_URL=https://evil.example/maple.zip \
    FEDORA_JETBRAINS_MAPLE_SHA256=$(printf '%064d' 1) \
    bash -c '
        source "$SHORIN_ROOT/scripts/lib/core.sh"
        [ "$FEDORA_STARSHIP_URL" = "$FEDORA_STARSHIP_URL_PINNED" ]
        [ "$FEDORA_STARSHIP_SHA256" = "$FEDORA_STARSHIP_SHA256_PINNED" ]
        [ "$FEDORA_JETBRAINS_MAPLE_URL" = "$FEDORA_JETBRAINS_MAPLE_URL_PINNED" ]
        [ "$FEDORA_JETBRAINS_MAPLE_SHA256" = "$FEDORA_JETBRAINS_MAPLE_SHA256_PINNED" ]
        fedora_starship_source_contract_valid
        fedora_font_source_contract_valid ttf-jetbrains-maple-mono-nf-xx-xx
    '; then
    fail 'ordinary environment variables must not override production provider sources'
fi

[ "$(fedora_application_provider_kind starship)" = target-user ] ||
    fail 'Starship must be declared as a target-user provider'
[ "$(fedora_application_provider_kind ttf-jetbrains-mono-nerd)" = font ] ||
    fail 'Nerd Font must be declared as a font provider'
[ "$(fedora_application_provider_kind material-design-icons)" = font ] ||
    fail 'Material Design Icons must be declared as a font provider'
fedora_starship_source_contract_valid ||
    fail 'Starship provider source contract must remain pinned to the official release'
rm -f "$BIN_DIR/uname"
cat > "$BIN_DIR/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SHORIN_TEST_UNAME:-x86_64}"
EOF
chmod 755 "$BIN_DIR/uname"
status=0
SHORIN_TEST_UNAME=aarch64 fedora_provider_architecture_satisfied || status=$?
[ "$status" -ne 0 ] || fail 'unsupported Fedora provider architecture was accepted'
for provider_target in ttf-jetbrains-mono-nerd \
    ttf-jetbrains-maple-mono-nf-xx-xx material-design-icons; do
    fedora_font_source_contract_valid "$provider_target" ||
        fail "font provider source contract rejected test seam: $provider_target"
done

# Archive safety rejects traversal, symlink/hardlink entries, and non-whitelist
# font names before any target-user directory is touched.
mkdir -p "$ASSET_DIR/unsafe"
ln -s "$ASSET_DIR/starship" "$ASSET_DIR/unsafe/starship"
tar -czf "$ASSET_DIR/unsafe-starship-link.tar.gz" -C "$ASSET_DIR/unsafe" starship
if fedora_starship_archive_entries_safe "$ASSET_DIR/unsafe-starship-link.tar.gz"; then
    fail 'Starship symlink archive entry was accepted'
fi
tar -cJf "$ASSET_DIR/unsafe-font-link.tar.xz" -C "$ASSET_DIR/unsafe" starship
if fedora_font_archive_entries_safe "$ASSET_DIR/unsafe-font-link.tar.xz" nerd; then
    fail 'Nerd Font symlink archive entry was accepted'
fi
printf 'font\n' > "$ASSET_DIR/unsafe/JetBrainsMonoNerdFont-Thin.ttf"
ln "$ASSET_DIR/unsafe/JetBrainsMonoNerdFont-Thin.ttf" \
    "$ASSET_DIR/unsafe/JetBrainsMonoNerdFont-Regular.ttf"
ln "$ASSET_DIR/unsafe/JetBrainsMonoNerdFont-Thin.ttf" \
    "$ASSET_DIR/unsafe/JetBrainsMonoNerdFont-Bold.ttf"
tar -cJf "$ASSET_DIR/unsafe-font-hardlink.tar.xz" -C "$ASSET_DIR/unsafe" \
    JetBrainsMonoNerdFont-Thin.ttf JetBrainsMonoNerdFont-Regular.ttf \
    JetBrainsMonoNerdFont-Bold.ttf
if fedora_font_archive_entries_safe "$ASSET_DIR/unsafe-font-hardlink.tar.xz" nerd; then
    fail 'Nerd Font hardlink archive entry was accepted'
fi
tar --transform='s#starship#../starship#' -czf \
    "$ASSET_DIR/unsafe-starship-traversal.tar.gz" -C "$ASSET_DIR/starship-root" starship
if fedora_starship_archive_entries_safe \
    "$ASSET_DIR/unsafe-starship-traversal.tar.gz"; then
    fail 'Starship traversal archive entry was accepted'
fi
fedora_nerd_font_file_name_allowed 'JetBrainsMonoNerdFont-Regular.ttf' ||
    fail 'Nerd Font whitelist rejected a valid family file'
if fedora_nerd_font_file_name_allowed 'evil.ttf'; then
    fail 'Nerd Font whitelist accepted a non-whitelist file'
fi
fedora_nerd_font_file_name_ignored 'JetBrainsMonoNLNerdFont-Regular.ttf' ||
    fail 'official no-ligature Nerd Font variant was not classified as ignored'
if fedora_nerd_font_file_name_ignored 'evil.ttf'; then
    fail 'Nerd Font ignore list accepted an arbitrary file'
fi

cat > "$BIN_DIR/fc-cache" <<'EOF'
#!/usr/bin/env bash
[ "${FC_CACHE_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
cat > "$BIN_DIR/fc-match" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
format=$2
family=${*: -1}
font_dir="$HOME/.local/share/fonts/shorin"
case "$family" in
    'JetBrainsMono Nerd Font') file=$(find "$font_dir" -type f -name 'JetBrainsMonoNerdFont*.ttf' -print -quit 2>/dev/null || true) ;;
    'JetBrains Maple Mono') file=$(find "$font_dir" -type f -name 'JetBrainsMapleMono*.ttf' -print -quit 2>/dev/null || true) ;;
    'Material Design Icons') file="$font_dir/materialdesignicons-webfont.ttf"; [ -f "$file" ] || file='' ;;
    *) file='' ;;
esac
[ -n "$file" ] || { printf 'Fallback\n'; exit 0; }
case "$format" in
    *'%{file'*) printf '%s\n' "$file" ;;
    *) printf '%s\n' "$family" ;;
esac
EOF
cat > "$BIN_DIR/fc-query" <<'EOF'
#!/usr/bin/env bash
format=$2
file=${*: -1}
case "$format" in
    *'%{family'*)
        case "$(basename "$file")" in
            JetBrainsMono*) printf 'JetBrainsMono Nerd Font\n' ;;
            JetBrainsMaple*) printf 'JetBrains Maple Mono\n' ;;
            materialdesign*) printf 'Material Design Icons\n' ;;
        esac
        ;;
    *'%{charset'*) printf 'f033e f0425 f0493\n' ;;
esac
EOF
cp "$BIN_DIR/fc-query" "$BIN_DIR/fc-scan"
chmod 755 "$BIN_DIR/fc-cache" "$BIN_DIR/fc-match" "$BIN_DIR/fc-query" \
    "$BIN_DIR/fc-scan"
fedora_target_user_provider_prerequisites_satisfied "$TARGET_USER" "$HOME_DIR" ||
    fail 'target-user Fedora provider prerequisites were not visible to the user'

curl() {
    local output=''
    [ "${CURL_FAIL:-0}" = 1 ] && return 1
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then
            output=$2
            shift 2
        else
            shift
        fi
    done
    printf '%s\n' "$output" >> "$CALLS"
    case "$output" in
        */starship.tar.gz) cp "$ASSET_DIR/starship.tar.gz" "$output" ;;
        */JetBrainsMono.tar.xz) cp "$ASSET_DIR/nerd.tar.xz" "$output" ;;
        */JetBrainsMapleMono.zip) cp "$ASSET_DIR/maple.zip" "$output" ;;
        */materialdesignicons-webfont.ttf) cp "$ASSET_DIR/mdi.ttf" "$output" ;;
        *) return 1 ;;
    esac
}

sha256sum() {
    local input

    if [ "${1:-}" = -c ]; then
        input=$(cat)
        if [ -n "${SHA256SUM_FAIL_TARGET:-}" ] &&
            [[ "$input" == *"$SHA256SUM_FAIL_TARGET"* ]]; then
            return 1
        fi
        return 0
    fi
    /usr/bin/sha256sum "$@"
}

fedora_provider_lock_acquire || fail 'provider global flock could not be acquired'
[ -n "${FEDORA_PROVIDER_LOCK_FD:-}" ] || fail 'provider global flock did not expose a lock fd'
fedora_provider_lock_release

race_file="$TEST_DIR/race-file"
printf 'provider output\n' > "$race_file"
race_identity=$(fedora_provider_file_identity "$race_file") ||
    fail 'provider output identity could not be recorded'
rm -f "$race_file"
printf 'concurrent user output\n' > "$race_file"
if fedora_provider_remove_if_unchanged "$race_file" "$race_identity"; then
    fail 'rollback removed a concurrently replaced user file'
fi
[ -f "$race_file" ] || fail 'rollback conflict did not preserve user file'

fedora_install_starship "$TARGET_USER" "$HOME_DIR" ||
    fail 'pinned Starship provider did not converge'
[ -x "$HOME_DIR/.local/bin/starship" ] || fail 'Starship binary missing'
before_starship_calls=$(wc -l < "$CALLS")
fedora_install_starship "$TARGET_USER" "$HOME_DIR" ||
    fail 'Starship provider is not idempotent'
[ "$(wc -l < "$CALLS")" -eq "$before_starship_calls" ] ||
    fail 'Starship provider redownloaded an existing usable command'

rm -f "$HOME_DIR/.local/bin/starship"
status=0
CURL_FAIL=1 fedora_install_starship "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'Starship network failure must fail closed'
[ ! -e "$HOME_DIR/.local/bin/starship" ] ||
    fail 'Starship network failure left a half-installed command'

fedora_install_desktop_font_provider "$TARGET_USER" "$HOME_DIR" ||
    fail 'pinned Fedora font providers did not converge'
fedora_font_target_satisfied ttf-jetbrains-mono-nerd "$TARGET_USER" "$HOME_DIR" ||
    fail 'Nerd Font family contract did not converge'
fedora_font_target_satisfied ttf-jetbrains-maple-mono-nf-xx-xx \
    "$TARGET_USER" "$HOME_DIR" ||
    fail 'Maple Mono family contract did not converge'
fedora_font_target_satisfied material-design-icons "$TARGET_USER" "$HOME_DIR" ||
    fail 'Material Design Icons family/glyph contract did not converge'
before_font_calls=$(wc -l < "$CALLS")
fedora_install_desktop_font_provider "$TARGET_USER" "$HOME_DIR" ||
    fail 'font provider is not idempotent'
[ "$(wc -l < "$CALLS")" -eq "$before_font_calls" ] ||
    fail 'font provider redownloaded exact families'

# Maple is conditional on the active Kitty configuration.  Removing the
# active reference must skip both its download and its acceptance contract.
printf 'font_family JetBrains Mono\n' > "$HOME_DIR/.config/kitty/kitty.conf"
rm -f "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMapleMono-NF-Regular.ttf"
before_no_maple_calls=$(wc -l < "$CALLS")
fedora_install_desktop_font_provider "$TARGET_USER" "$HOME_DIR" ||
    fail 'font provider without active Maple config did not converge'
[ "$(wc -l < "$CALLS")" -eq "$before_no_maple_calls" ] ||
    fail 'inactive Maple config still triggered a download'
[ ! -e "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMapleMono-NF-Regular.ttf" ] ||
    fail 'inactive Maple config still installed Maple fonts'
if fedora_font_target_satisfied ttf-jetbrains-maple-mono-nf-xx-xx \
    "$TARGET_USER" "$HOME_DIR"; then
    fail 'explicit Maple target was incorrectly treated as optional'
fi
printf 'font_family JetBrains Maple Mono\n' > "$HOME_DIR/.config/kitty/kitty.conf"
fedora_install_font_provider_target ttf-jetbrains-maple-mono-nf-xx-xx \
    "$TARGET_USER" "$HOME_DIR" || fail 'active Maple config did not restore its provider'

# A usable user-installed command/family is accepted without touching the
# pinned assets.  The custom command/font remain byte-for-byte intact.
rm -f "$HOME_DIR/.local/bin/starship"
printf '#!/usr/bin/env bash\nprintf "starship 9.9.9\\n"\n' > \
    "$HOME_DIR/.local/bin/starship"
chmod 755 "$HOME_DIR/.local/bin/starship"
fedora_install_starship "$TARGET_USER" "$HOME_DIR" ||
    fail 'existing user Starship command must be accepted'
grep -Fq '9.9.9' "$HOME_DIR/.local/bin/starship" ||
    fail 'existing user Starship command was overwritten'

rm -f "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMonoNerdFont-Regular.ttf"
printf 'user-owned nerd font\n' > \
    "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMonoNerdFont-User.ttf"
before_user_font=$(cat "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMonoNerdFont-User.ttf")
fedora_install_font_provider_target ttf-jetbrains-mono-nerd \
    "$TARGET_USER" "$HOME_DIR" || fail 'existing user font must be accepted'
[ "$(cat "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMonoNerdFont-User.ttf")" = \
    "$before_user_font" ] || fail 'existing user font was overwritten'

# A fontconfig failure rolls back only this transaction and leaves every
# already-installed font untouched.
rm -f "$HOME_DIR/.local/share/fonts/shorin/materialdesignicons-webfont.ttf"
before_rollback_fonts=$(find "$HOME_DIR/.local/share/fonts/shorin" -type f -print | sort)
status=0
FC_CACHE_FAIL=1 fedora_install_font_provider_target material-design-icons \
    "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'fc-cache failure must fail the font provider'
[ ! -e "$HOME_DIR/.local/share/fonts/shorin/materialdesignicons-webfont.ttf" ] ||
    fail 'fc-cache failure left a half-installed font'
[ "$(find "$HOME_DIR/.local/share/fonts/shorin" -type f -print | sort)" = \
    "$before_rollback_fonts" ] || fail 'fc-cache rollback damaged existing fonts'

# A checksum failure is fail-closed and leaves all pre-existing assets intact.
before_nerd=$(find "$HOME_DIR/.local/share/fonts/shorin" -type f -print | sort)
rm -f "$HOME_DIR/.local/bin/starship"
status=0
SHA256SUM_FAIL_TARGET=materialdesignicons-webfont.ttf \
fedora_install_desktop_providers "$TARGET_USER" "$HOME_DIR" \
    || status=$?
[ "$status" -ne 0 ] || fail 'cross-provider bad checksum must fail'
[ ! -e "$HOME_DIR/.local/bin/starship" ] ||
    fail 'cross-provider rollback left a half-installed Starship command'
[ ! -e "$HOME_DIR/.local/share/fonts/shorin/materialdesignicons-webfont.ttf" ] ||
    fail 'cross-provider rollback left a half-installed MDI font'
[ "$(find "$HOME_DIR/.local/share/fonts/shorin" -type f -print | sort)" = \
    "$before_nerd" ] || fail 'cross-provider rollback damaged existing fonts'
fedora_install_desktop_providers "$TARGET_USER" "$HOME_DIR" ||
    fail 'cross-provider transaction did not recover after checksum repair'

rm -f "$HOME_DIR/.local/share/fonts/shorin/materialdesignicons-webfont.ttf"
status=0
SHA256SUM_FAIL_TARGET=materialdesignicons-webfont.ttf \
fedora_install_font_provider_target material-design-icons \
    "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'bad font checksum must fail'
[ ! -e "$HOME_DIR/.local/share/fonts/shorin/materialdesignicons-webfont.ttf" ] ||
    fail 'bad font checksum left a half-installed font'
[ "$(find "$HOME_DIR/.local/share/fonts/shorin" -type f -print | sort)" = \
    "$before_nerd" ] || fail 'bad font checksum damaged existing fonts'
unset SHA256SUM_FAIL_TARGET

source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"
if fedora_arch_target_name ttf-jetbrains-mono-nerd >/dev/null 2>&1; then
    fail 'Fedora Nerd Font target still has a fake DNF mapping'
fi
printf 'font_family JetBrains Mono\n' > "$HOME_DIR/.config/kitty/kitty.conf"
rm -f "$HOME_DIR/.local/share/fonts/shorin/JetBrainsMapleMono-NF-Regular.ttf"
if niri_package_target_satisfied AUR:ttf-jetbrains-maple-mono-nf-xx-xx; then
    fail 'manifest-declared Fedora Maple target was incorrectly skipped'
fi
export SHORIN_DISTRO=arch
[ "$(niri_package_target_canonical AUR:ttf-jetbrains-maple-mono-nf-xx-xx)" = \
    AUR:ttf-jetbrains-maple-mono-nf-xx-xx ] || fail 'Arch Maple target was not preserved'
export SHORIN_DISTRO=fedora

grep -Fq 'provider:font:material-design-icons' \
    "$ROOT_DIR/scripts/modules/desktop-niri.sh" ||
    fail 'desktop-niri provider MODULE_REASON contract is missing'
grep -Fq 'fedora_install_desktop_providers' \
    "$ROOT_DIR/scripts/modules/desktop-niri/fedora-provider-apply.sh" ||
    fail 'desktop-niri Fedora apply helper does not invoke the provider transaction'

printf 'PASS: Fedora Starship and exact font providers\n'
