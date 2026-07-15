#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 99-apps.sh - Common Applications (Repo/AUR/Flatpak/GitHub + Retry Logic)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"
source "$SCRIPT_DIR/99-github-apps.sh"

# --- [CONFIGURATION] ---
# LazyVim 硬性依赖列表 (Moved from niri-setup)
LAZYVIM_DEPS=("neovim" "ripgrep" "fd" "ttf-jetbrains-mono-nerd" "git")

check_root

# Ensure FZF is installed
if ! command -v fzf &> /dev/null; then
    log "Installing dependency: fzf..."
    ensure_package fzf
fi

trap 'echo -e "\n   ${H_YELLOW}>>> Operation cancelled by user.${NC}"; exit 130' INT

# ------------------------------------------------------------------------------
# 0. Identify Target User & Helper
# ------------------------------------------------------------------------------
section "Phase 5" "Common Applications"

log "Identifying target user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
else
    read -p "   Please enter the target username: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# Helper function for user commands
as_user() {
  runuser -u "$TARGET_USER" -- "$@"
}

# ------------------------------------------------------------------------------
# 1. List Selection & User Prompt
# ------------------------------------------------------------------------------
LIST_FILENAME="common-applist.txt"
LIST_FILE="$PARENT_DIR/$LIST_FILENAME"

REPO_APPS=()
AUR_APPS=()
FLATPAK_APPS=()
GITHUB_APPS=()
FAILED_PACKAGES=()
INSTALL_LAZYVIM=false
SUDO_TEMP_FILE=""

if [ ! -f "$LIST_FILE" ]; then
    warn "File $LIST_FILENAME not found. Skipping."
    trap - INT
    exit 20
fi

if ! grep -q -vE "^\s*#|^\s*$" "$LIST_FILE"; then
    warn "App list is empty. Skipping."
    trap - INT
    exit 20
fi

echo ""
echo -e "   Selected List: ${BOLD}$LIST_FILENAME${NC}"
echo -e "   ${H_YELLOW}>>> Do you want to install common applications?${NC}"
echo -e "   ${H_CYAN}    [ENTER] = Select packages${NC}"
echo -e "   ${H_CYAN}    [N]     = Skip installation${NC}"
echo -e "   ${H_YELLOW}    [Timeout 60s] = Auto-install ALL default packages (No FZF)${NC}"
echo ""

if read -r -t 60 -p "   Please select [Y/n]: " choice; then
    READ_STATUS=0
else
    READ_STATUS=$?
fi

SELECTED_RAW=""

# Case 1: Timeout (Auto Install ALL)
if [ $READ_STATUS -ne 0 ]; then
    echo "" 
    warn "Timeout reached (60s). Auto-installing ALL applications from list..."
    SELECTED_RAW=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed -E 's/[[:space:]]+#/\t#/')

# Case 2: User Input
else
    choice=${choice:-Y}
    if [[ "$choice" =~ ^[nN]$ ]]; then
        warn "User skipped application installation."
        trap - INT
        exit 20
    else
        clear
        echo -e "\n  Loading application list..."
        
        SELECTED_RAW=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | \
            sed -E 's/[[:space:]]+#/\t#/' | \
            fzf --multi \
                --layout=reverse \
                --border \
                --margin=1,2 \
                --prompt="Search App > " \
                --pointer=">>" \
                --marker="* " \
                --delimiter=$'\t' \
                --with-nth=1 \
                --bind 'load:select-all' \
                --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
                --info=inline \
                --header="[TAB] TOGGLE | [ENTER] INSTALL | [CTRL-D] DE-ALL | [CTRL-A] SE-ALL" \
                --preview "echo {} | cut -f2 -d$'\t' | sed 's/^# //'" \
                --preview-window=right:45%:wrap:border-left \
                --color=dark \
                --color=fg+:white,bg+:black \
                --color=hl:blue,hl+:blue:bold \
                --color=header:yellow:bold \
                --color=info:magenta \
                --color=prompt:cyan,pointer:cyan:bold,marker:green:bold \
                --color=spinner:yellow)
        
        clear
        
        if [ -z "$SELECTED_RAW" ]; then
            log "Skipping application installation (User cancelled selection)."
            trap - INT
            exit 20
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 2. Categorize Selection & Strip Prefixes (Includes LazyVim Check)
# ------------------------------------------------------------------------------
log "Processing selection..."

while IFS= read -r line; do
    raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
    [[ -z "$raw_pkg" ]] && continue

    # Check for LazyVim explicitly (Case insensitive check)
    if [[ "${raw_pkg,,}" == "lazyvim" ]]; then
        INSTALL_LAZYVIM=true
        REPO_APPS+=("${LAZYVIM_DEPS[@]}")
        info_kv "Config" "LazyVim detected" "Setup deferred to Post-Install"
        continue
    fi

    if [[ "$raw_pkg" == flatpak:* ]]; then
        clean_name="${raw_pkg#flatpak:}"
        FLATPAK_APPS+=("$clean_name")
    elif [[ "$raw_pkg" == GitHub:* ]]; then
        clean_name="${raw_pkg#GitHub:}"
        if github_deps=$(github_app_dependencies "$clean_name"); then
            GITHUB_APPS+=("$clean_name")
            read -r -a github_dep_array <<< "$github_deps"
            REPO_APPS+=("${github_dep_array[@]}")
        else
            warn "Unsupported GitHub application in $LIST_FILENAME: $clean_name"
            FAILED_PACKAGES+=("github:$clean_name")
        fi
    elif [[ "$raw_pkg" == AUR:* ]]; then
        clean_name="${raw_pkg#AUR:}"
        AUR_APPS+=("$clean_name")
    else
        REPO_APPS+=("$raw_pkg")
    fi
done <<< "$SELECTED_RAW"

info_kv "Scheduled" "Repo: ${#REPO_APPS[@]} | AUR: ${#AUR_APPS[@]} | Flatpak: ${#FLATPAK_APPS[@]} | GitHub: ${#GITHUB_APPS[@]}"

# ------------------------------------------------------------------------------
# [SETUP] GLOBAL SUDO CONFIGURATION
# ------------------------------------------------------------------------------
if [ ${#REPO_APPS[@]} -gt 0 ] || [ ${#AUR_APPS[@]} -gt 0 ]; then
    log "Configuring temporary NOPASSWD for installation..."
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_apps"
    SUDO_TEMP_SOURCE=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" > "$SUDO_TEMP_SOURCE"
    install_sudoers_file "$SUDO_TEMP_SOURCE" "$SUDO_TEMP_FILE"
    rm -f "$SUDO_TEMP_SOURCE"
    cleanup_temp_sudoers() {
        [ ! -f "$SUDO_TEMP_FILE" ] || rm -f "$SUDO_TEMP_FILE"
    }
    trap cleanup_temp_sudoers EXIT
fi

# ------------------------------------------------------------------------------
# 3. Install Applications
# ------------------------------------------------------------------------------

# --- A. Install Repo Apps (individual convergence) ---
if [ ${#REPO_APPS[@]} -gt 0 ]; then
    section "Step 1/4" "Official Repository Packages"
    mapfile -t REPO_APPS < <(printf '%s\n' "${REPO_APPS[@]}" | sort -u)
    for pkg in "${REPO_APPS[@]}"; do
        if ! ensure_package "$pkg"; then
            FAILED_PACKAGES+=("repo:$pkg")
        fi
    done
fi

# --- B. Install AUR Apps (INDIVIDUAL MODE + RETRY) ---
if [ ${#AUR_APPS[@]} -gt 0 ]; then
    section "Step 2/4" "AUR Packages (Sequential + Retry)"
    
    for app in "${AUR_APPS[@]}"; do
        if pacman -Qi "$app" &>/dev/null; then
            log "Skipping '$app' (Already installed)."
            continue
        fi


        log "Installing AUR: $app ..."
        install_success=false
        max_retries=2
        
        for (( i=0; i<=max_retries; i++ )); do
            if [ $i -gt 0 ]; then
                warn "Retry $i/$max_retries for '$app' in 3 seconds..."
                sleep 3
            fi
            
            if ensure_aur_package "$app" "$TARGET_USER"; then
                install_success=true
                success "Installed $app"
                break
            else
                warn "Attempt $((i+1)) failed for $app"
            fi
        done

        if [ "$install_success" = false ]; then
            error "Failed to install $app after $((max_retries+1)) attempts."
            FAILED_PACKAGES+=("aur:$app")
        fi
    done
fi

# --- C. Install Flatpak Apps (INDIVIDUAL MODE) ---
if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
    section "Step 3/4" "Flatpak Packages (Individual)"
    
    for app in "${FLATPAK_APPS[@]}"; do
        if flatpak info --system "$app" &>/dev/null; then
            log "Skipping '$app' (Already installed)."
            continue
        fi

        log "Installing Flatpak: $app ..."
        if ! ensure_flatpak "$app"; then
            error "Failed to install: $app"
            FAILED_PACKAGES+=("flatpak:$app")
        else
            success "Installed $app"
        fi
    done
fi

# --- D. Build Custom GitHub Apps (INDIVIDUAL MODE) ---
if [ ${#GITHUB_APPS[@]} -gt 0 ]; then
    section "Step 4/4" "Custom GitHub Applications (Build from Source)"

    for app in "${GITHUB_APPS[@]}"; do
        log "Installing GitHub application: $app ..."
        if install_github_app "$app"; then
            success "Installed $app from GitHub."
        else
            error "Failed to install GitHub application: $app"
            FAILED_PACKAGES+=("github:$app")
        fi
    done
fi

# ------------------------------------------------------------------------------
# 4. Converge application-specific configuration
# ------------------------------------------------------------------------------
source "$SCRIPT_DIR/99-app-config.sh"

# ------------------------------------------------------------------------------
# [FIX] CLEANUP GLOBAL SUDO CONFIGURATION
# ------------------------------------------------------------------------------
if [ -n "$SUDO_TEMP_FILE" ] && [ -f "$SUDO_TEMP_FILE" ]; then
    log "Revoking temporary NOPASSWD..."
    rm -f "$SUDO_TEMP_FILE"
fi

# ------------------------------------------------------------------------------
# 5. Generate Failure Report
# ------------------------------------------------------------------------------
if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    DOCS_DIR="$HOME_DIR/Documents"
    REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
    
    if [ ! -d "$DOCS_DIR" ]; then as_user mkdir -p "$DOCS_DIR"; fi
    
    REPORT_TMP=$(mktemp)
    printf 'Installation Failure Report - %s\n\n' "$(date)" > "$REPORT_TMP"
    printf "%s\n" "${FAILED_PACKAGES[@]}" >> "$REPORT_TMP"
    install_if_changed "$REPORT_TMP" "$REPORT_FILE" 600
    rm -f "$REPORT_TMP"
    chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
    
    echo ""
    warn "Some applications failed to install."
    warn "A report has been saved to:"
    echo -e "   ${BOLD}$REPORT_FILE${NC}"
    exit 1
else
    success "All scheduled applications processed successfully."
fi

if [ "${#USER_UNIT_PENDING[@]}" -gt 0 ]; then
    warn "User services are enabled but pending login: ${USER_UNIT_PENDING[*]}"
    exit 20
fi

# Reset Trap
trap - INT

log "Module 99-apps completed."
