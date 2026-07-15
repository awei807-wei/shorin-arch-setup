#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 07-grub-theme.sh - GRUB Theming & Advanced Configuration
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PARENT_DIR="${SHORIN_ROOT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/grub/contract.sh"

check_root
grub_contract_init

# ------------------------------------------------------------------------------
# 0. Pre-check: Is GRUB installed?
# ------------------------------------------------------------------------------
if ! command -v grub-mkconfig >/dev/null 2>&1; then
    echo ""
    warn "GRUB (grub-mkconfig) not found on this system."
    log "Skipping GRUB theme installation."
    exit 20
fi
[ -f "$GRUB_DEFAULT_FILE" ] || die "Missing GRUB defaults: $GRUB_DEFAULT_FILE"
if ! grub_theme_is_available; then
    warn "No GRUB theme assets are available in $GRUB_THEME_SOURCE_ROOT."
    exit 20
fi

section "Phase 7" "GRUB Customization & Theming"

# --- Helper Functions (Moved from 02a) ---

set_grub_value() {
    local key="$1"
    local value="$2"
    local conf_file="$GRUB_DEFAULT_FILE"
    ensure_key_value "$conf_file" "$key" "\"$value\""
}

manage_kernel_param() {
    local action="$1"
    local param="$2"
    local conf_file="$GRUB_DEFAULT_FILE"
    local line
    line=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$conf_file" || true)
    local params
    params=$(echo "$line" | sed -e 's/GRUB_CMDLINE_LINUX_DEFAULT=//' -e 's/"//g')
    local param_key
    if [[ "$param" == *"="* ]]; then param_key="${param%%=*}"; else param_key="$param"; fi
    params=$(echo "$params" | sed -E "s/\b${param_key}(=[^ ]*)?\b//g")

    if [ "$action" == "add" ]; then params="$params $param"; fi

    params=$(echo "$params" | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ensure_key_value "$conf_file" GRUB_CMDLINE_LINUX_DEFAULT "\"$params\""
}

# ------------------------------------------------------------------------------
# 1. Advanced GRUB Configuration (Moved from 02a)
# ------------------------------------------------------------------------------
section "Step 1/5" "General GRUB Settings"

log "Enabling GRUB to remember the last selected entry..."
set_grub_value "GRUB_DEFAULT" "saved"
set_grub_value "GRUB_SAVEDEFAULT" "true"

log "Configuring kernel boot parameters for detailed logs and performance..."
manage_kernel_param "remove" "quiet"
manage_kernel_param "remove" "splash"
manage_kernel_param "add" "loglevel=5"
manage_kernel_param "add" "nowatchdog"

# CPU Watchdog Logic
CPU_VENDOR=$(LC_ALL=C lscpu | awk -F: '/Vendor ID/ { gsub(/^[[:space:]]+/, "", $2); print $2 }')
if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    log "Intel CPU detected. Disabling iTCO_wdt watchdog."
    manage_kernel_param "add" "modprobe.blacklist=iTCO_wdt"
elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    log "AMD CPU detected. Disabling sp5100_tco watchdog."
    manage_kernel_param "add" "modprobe.blacklist=sp5100_tco"
fi

success "Kernel parameters updated."

# ------------------------------------------------------------------------------
# 2. Detect Themes
# ------------------------------------------------------------------------------
section "Step 2/5" "Theme Detection"
log "Scanning for themes in 'grub-themes' folder..."

SOURCE_BASE="$GRUB_THEME_SOURCE_ROOT"
DEST_DIR="$GRUB_THEME_DEST_ROOT"

if [ ! -d "$SOURCE_BASE" ]; then
    warn "Directory 'grub-themes' not found in repo."
    exit 20
fi

mapfile -t FOUND_DIRS < <(find "$SOURCE_BASE" -mindepth 1 -maxdepth 1 -type d | sort)
THEME_PATHS=()
THEME_NAMES=()

for dir in "${FOUND_DIRS[@]}"; do
    if [ -f "$dir/theme.txt" ]; then
        THEME_PATHS+=("$dir")
        THEME_NAMES+=("$(basename "$dir")")
    fi
done

if [ ${#THEME_NAMES[@]} -eq 0 ]; then
    warn "No valid theme folders found."
    exit 20
fi

# ------------------------------------------------------------------------------
# 3. Select Theme (TUI Menu)
# ------------------------------------------------------------------------------
section "Step 3/5" "Theme Selection"

if [ "${SHORIN_MODE:-install}" != install ]; then
    CURRENT_THEME=$(awk -F= '$1 == "GRUB_THEME" { gsub(/"/, "", $2); print $2 }' \
        "$GRUB_DEFAULT_FILE" | tail -n 1)
    CURRENT_THEME_DIR=$(basename "$(dirname "${CURRENT_THEME:-/nonexistent/theme.txt}")")
    SELECTED_INDEX=0
    for i in "${!THEME_NAMES[@]}"; do
        if [[ "$CURRENT_THEME_DIR" == "${THEME_NAMES[$i]}"-* ]] ||
            [ "$CURRENT_THEME_DIR" = "${THEME_NAMES[$i]}" ]; then
            SELECTED_INDEX=$i
            break
        fi
    done
elif [ ${#THEME_NAMES[@]} -eq 1 ]; then
    SELECTED_INDEX=0
    log "Only one theme detected. Auto-selecting: ${THEME_NAMES[0]}"
else
    # Calculation & Menu Rendering
    TITLE_TEXT="Select GRUB Theme (60s Timeout)"
    MAX_LEN=${#TITLE_TEXT}
    for name in "${THEME_NAMES[@]}"; do
        ITEM_LEN=$((${#name} + 20))
        if (( ITEM_LEN > MAX_LEN )); then MAX_LEN=$ITEM_LEN; fi
    done
    MENU_WIDTH=$((MAX_LEN + 4))
    
    LINE_STR=""; printf -v LINE_STR "%*s" "$MENU_WIDTH" ""; LINE_STR=${LINE_STR// /─}

    echo -e "\n${H_PURPLE}╭${LINE_STR}╮${NC}"
    TITLE_PADDING_LEN=$(( (MENU_WIDTH - ${#TITLE_TEXT}) / 2 ))
    RIGHT_PADDING_LEN=$((MENU_WIDTH - ${#TITLE_TEXT} - TITLE_PADDING_LEN))
    T_PAD_L=""; printf -v T_PAD_L "%*s" "$TITLE_PADDING_LEN" ""
    T_PAD_R=""; printf -v T_PAD_R "%*s" "$RIGHT_PADDING_LEN" ""
    echo -e "${H_PURPLE}│${NC}${T_PAD_L}${BOLD}${TITLE_TEXT}${NC}${T_PAD_R}${H_PURPLE}│${NC}"
    echo -e "${H_PURPLE}├${LINE_STR}┤${NC}"

    for i in "${!THEME_NAMES[@]}"; do
        NAME="${THEME_NAMES[$i]}"
        DISPLAY_IDX=$((i+1))
        if [ "$i" -eq 0 ]; then
            COLOR_STR=" ${H_CYAN}[$DISPLAY_IDX]${NC} ${NAME} - ${H_GREEN}Default${NC}"
            RAW_STR=" [$DISPLAY_IDX] $NAME - Default"
        else
            COLOR_STR=" ${H_CYAN}[$DISPLAY_IDX]${NC} ${NAME}"
            RAW_STR=" [$DISPLAY_IDX] $NAME"
        fi
        PADDING=$((MENU_WIDTH - ${#RAW_STR}))
        PAD_STR=""; if [ "$PADDING" -gt 0 ]; then printf -v PAD_STR "%*s" "$PADDING" ""; fi
        echo -e "${H_PURPLE}│${NC}${COLOR_STR}${PAD_STR}${H_PURPLE}│${NC}"
    done
    echo -e "${H_PURPLE}╰${LINE_STR}╯${NC}\n"

    echo -ne "   ${H_YELLOW}Enter choice [1-${#THEME_NAMES[@]}]: ${NC}"
    if ! read -r -t 60 USER_CHOICE; then
        USER_CHOICE=1
    fi
    if [ -z "$USER_CHOICE" ]; then echo ""; fi
    USER_CHOICE=${USER_CHOICE:-1}

    if ! [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] || [ "$USER_CHOICE" -lt 1 ] || [ "$USER_CHOICE" -gt "${#THEME_NAMES[@]}" ]; then
        log "Invalid choice or timeout. Defaulting to first option..."
        SELECTED_INDEX=0
    else
        SELECTED_INDEX=$((USER_CHOICE-1))
    fi
fi

THEME_SOURCE="${THEME_PATHS[$SELECTED_INDEX]}"
THEME_NAME="${THEME_NAMES[$SELECTED_INDEX]}"
info_kv "Selected" "$THEME_NAME"

# ------------------------------------------------------------------------------
# 4. Install & Configure Theme
# ------------------------------------------------------------------------------
section "Step 4/5" "Theme Installation"

mkdir -p "$DEST_DIR"
THEME_HASH=$(grub_theme_hash "$THEME_SOURCE")
THEME_INSTALL_NAME="${THEME_NAME}-${THEME_HASH}"
THEME_STAGED=$(mktemp -d "$DEST_DIR/.${THEME_NAME}.XXXXXX")
cp -a "$THEME_SOURCE/." "$THEME_STAGED/"
if [ "$(grub_theme_hash "$THEME_STAGED")" != "$THEME_HASH" ]; then
    find "$THEME_STAGED" -depth -delete
    die 'Staged GRUB theme failed content verification.'
fi
THEME_TARGET="$DEST_DIR/$THEME_INSTALL_NAME"
if [ -d "$THEME_TARGET" ] &&
    [ "$(grub_theme_hash "$THEME_TARGET")" = "$THEME_HASH" ]; then
    find "$THEME_STAGED" -depth -delete
else
    THEME_OLD="$DEST_DIR/.${THEME_INSTALL_NAME}.old.$$"
    [ ! -e "$THEME_OLD" ] || find "$THEME_OLD" -depth -delete
    if [ -e "$THEME_TARGET" ]; then
        mv "$THEME_TARGET" "$THEME_OLD"
    fi
    if ! mv "$THEME_STAGED" "$THEME_TARGET"; then
        [ ! -e "$THEME_OLD" ] || mv "$THEME_OLD" "$THEME_TARGET"
        die 'Failed to activate the staged GRUB theme.'
    fi
    [ ! -e "$THEME_OLD" ] || find "$THEME_OLD" -depth -delete
fi

if [ -f "$DEST_DIR/$THEME_INSTALL_NAME/theme.txt" ]; then
    success "Theme installed."
else
    error "Failed to copy theme files."
    exit 1
fi

GRUB_CONF="$GRUB_DEFAULT_FILE"
THEME_PATH="$DEST_DIR/$THEME_INSTALL_NAME/theme.txt"

if [ -f "$GRUB_CONF" ]; then
    set_grub_value GRUB_THEME "$THEME_PATH"
    set_grub_value GRUB_TERMINAL_OUTPUT gfxterm
    set_grub_value GRUB_GFXMODE auto
    success "Configured GRUB to use theme."
else
    error "$GRUB_CONF not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Add Shutdown/Reboot Menu Entries
# ------------------------------------------------------------------------------
section "Step 5/5" "Menu Entries & Apply"
log "Adding Power Options to GRUB menu..."

CUSTOM_TMP=$(mktemp)
grub_custom_contract > "$CUSTOM_TMP"
install_if_changed "$CUSTOM_TMP" "$GRUB_CUSTOM_FILE" 755
rm -f "$CUSTOM_TMP"
grub_custom_matches
grub_theme_target_matches

# 赋予执行权限
success "Added grub menuentry 99-shutdown"
# ------------------------------------------------------------------------------
# 6. Apply Changes
# ------------------------------------------------------------------------------
log "Generating new GRUB configuration..."

GRUB_TMP=$(mktemp "${GRUB_CONFIG_FILE}.XXXXXX")
if grub-mkconfig -o "$GRUB_TMP" && grub-script-check "$GRUB_TMP"; then
    install_if_changed "$GRUB_TMP" "$GRUB_CONFIG_FILE" 600
    rm -f "$GRUB_TMP"
    success "GRUB updated successfully."
else
    rm -f "$GRUB_TMP"
    error "Failed to update GRUB."
    exit 1
fi

log "Module 07 completed."
