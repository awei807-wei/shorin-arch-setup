#!/usr/bin/env bash
# ==============================================================================
# install.sh - Shorin Arch Setup Entry Point
# (Reconstructed by Piko v5.0 - 2026-03-15)
# ==============================================================================

set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS_PATH="$SCRIPT_DIR/scripts"

# Load UI Engine
if [ -f "$SCRIPTS_PATH/00-utils.sh" ]; then
    source "$SCRIPTS_PATH/00-utils.sh"
else
    echo "Error: scripts/00-utils.sh not found!"
    exit 1
fi

check_root

# --- [MODULE DEFINITIONS] ---

BASE_MODULES=(
    "00-btrfs-init.sh"
    "01-base.sh"
    "02-musthave.sh"
    "02a-dualboot-fix.sh"
    "03-user.sh"
    "03b-gpu-driver.sh"
    "03c-snapshot-before-desktop.sh"
)

# Desktop Scripts (add your own here)
DESKTOP_SCRIPTS=(
    "Niri|04-niri-setup.sh"
)

select_desktop() {
    section "Desktop Environment" "Select your setup"
    local count=${#DESKTOP_SCRIPTS[@]}
    for i in "${!DESKTOP_SCRIPTS[@]}"; do
        local label="${DESKTOP_SCRIPTS[$i]%%|*}"
        echo -e "${H_BLUE}$((i+1)))${NC} $label"
    done
    echo -ne "${H_YELLOW}Choice [1-$count]: ${NC}"
    if ! read -r choice; then
        choice=1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
        DESKTOP_SCRIPT="${DESKTOP_SCRIPTS[$((choice-1))]#*|}"
    else
        warn "Invalid choice. Using the first declared desktop."
        DESKTOP_SCRIPT="${DESKTOP_SCRIPTS[0]#*|}"
    fi
}

# VCP integrations intentionally run after applications because they depend on
# an externally managed VCPChat tree.
OPTIONAL_MODULES=(
    "05-nas-rime-sync.sh"
    "99-apps.sh"
    "06-vcp-backup-setup.sh"
    "08-vcp-desktop-entry.sh"
    "07-grub-theme.sh"
)

OPTIONAL_FAILURES=()
OPTIONAL_SKIPS=()

run_required() {
    local script=$1
    local path="$SCRIPTS_PATH/$script"

    if [ ! -f "$path" ]; then
        error "Required module is missing: $script"
        printf 'INSTALL_STATUS=FAILED\n'
        exit 1
    fi
    if ! bash "$path"; then
        error "Required module failed: $script"
        printf 'INSTALL_STATUS=FAILED\n'
        exit 1
    fi
}

run_optional() {
    local script=$1
    local path="$SCRIPTS_PATH/$script"
    local status

    if [ ! -f "$path" ]; then
        OPTIONAL_SKIPS+=("$script:missing")
        return 0
    fi
    if bash "$path"; then
        return 0
    else
        status=$?
    fi

    if [ "$status" -eq 20 ]; then
        OPTIONAL_SKIPS+=("$script")
    else
        OPTIONAL_FAILURES+=("$script:$status")
    fi
}

verify_required_state() {
    local failures=()
    local package target_user home_dir
    local required_packages=(
        base-devel fastfetch flatpak power-profiles-daemon
        ttf-jetbrains-mono-nerd xdg-user-dirs yay
    )

    for package in "${required_packages[@]}"; do
        verify_package "$package" || failures+=("package:$package")
    done
    verify_service power-profiles-daemon.service ||
        failures+=("service:power-profiles-daemon.service")
    findmnt --verify >/dev/null 2>&1 || failures+=("fstab")

    if [ -f /tmp/shorin_install_user ]; then
        target_user=$(< /tmp/shorin_install_user)
        if getent passwd "$target_user" >/dev/null; then
            home_dir=$(getent passwd "$target_user" | cut -d: -f6)
            id -nG "$target_user" | tr ' ' '\n' | grep -Fqx wheel ||
                failures+=("group:$target_user:wheel")
            if [ "${DESKTOP_SCRIPT:-}" = "04-niri-setup.sh" ]; then
                verify_file "$home_dir/.config/niri/config.kdl" ||
                    failures+=("file:$home_dir/.config/niri/config.kdl")
                if [ -f /tmp/shorin_niri_user_unit_required ]; then
                    verify_user_unit "$target_user" niri-autostart.service ||
                        failures+=("user-unit:$target_user:niri-autostart.service")
                fi
            fi
        else
            failures+=("user:$target_user")
        fi
    else
        failures+=("state:target-user")
    fi

    if [ -s /boot/grub/grub.cfg ] && command -v grub-script-check >/dev/null 2>&1; then
        grub-script-check /boot/grub/grub.cfg >/dev/null 2>&1 ||
            failures+=("grub:/boot/grub/grub.cfg")
    fi

    if [ "${#failures[@]}" -gt 0 ]; then
        error "Required-state verification failed: ${failures[*]}"
        return 1
    fi
}

# --- [MAIN EXECUTION] ---

clear
section "Shorin Arch Setup" "System Deployment Started"

# 1. Execute Base Modules
for script in "${BASE_MODULES[@]}"; do
    run_required "$script"
done

# 2. Select & Execute Desktop Setup
select_desktop
run_required "$DESKTOP_SCRIPT"

# 3. Execute optional finalization modules
for script in "${OPTIONAL_MODULES[@]}"; do
    run_optional "$script"
done

# 4. Re-check declared state instead of trusting command history.
if ! verify_required_state; then
    printf 'INSTALL_STATUS=FAILED\n'
    exit 1
fi

if [ "${#OPTIONAL_FAILURES[@]}" -gt 0 ] || [ "${#OPTIONAL_SKIPS[@]}" -gt 0 ]; then
    warn "Required state is valid, but optional work is incomplete."
    [ "${#OPTIONAL_FAILURES[@]}" -eq 0 ] || warn "Failed: ${OPTIONAL_FAILURES[*]}"
    [ "${#OPTIONAL_SKIPS[@]}" -eq 0 ] || warn "Skipped: ${OPTIONAL_SKIPS[*]}"
    printf 'INSTALL_STATUS=PARTIAL\n'
else
    success "All required and optional targets passed verification."
    printf 'INSTALL_STATUS=SUCCESS\n'
fi
