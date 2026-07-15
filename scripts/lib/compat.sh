#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Compatibility surface for convergent apply implementations. No function in
# this file writes during source, so audit and verify remain read-only.

NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
H_RED='\033[1;31m'
H_GREEN='\033[1;32m'
H_YELLOW='\033[1;33m'
H_BLUE='\033[1;34m'
H_PURPLE='\033[1;35m'
H_MAGENTA='\033[1;35m'
H_CYAN='\033[1;36m'
H_WHITE='\033[1;37m'
H_GRAY='\033[1;90m'
TICK="${H_GREEN}[OK]${NC}"
CROSS="${H_RED}[X]${NC}"
INFO="${H_BLUE}[i]${NC}"
WARN="${H_YELLOW}[!]${NC}"
ARROW="${H_CYAN}->${NC}"
export NC BOLD DIM H_RED H_GREEN H_YELLOW H_BLUE H_PURPLE H_MAGENTA
export H_CYAN H_WHITE H_GRAY TICK CROSS INFO WARN ARROW

WARN_COUNT=0
declare -ag WARN_SUMMARY=()
declare -ag USER_UNIT_PENDING=()

check_root() {
    [ "$EUID" -eq 0 ] || die 'This operation must run as root.'
}

as_user() {
    local user=${TARGET_USER:-}
    [ -n "$user" ] || die 'TARGET_USER is not set.'
    runuser -u "$user" -- "$@"
}

section() {
    printf '\n== %s ==\n%s\n' "$1" "${2:-}"
}

info_kv() {
    printf '%-18s %s %s\n' "$1:" "$2" "${3:-}"
}

success() {
    printf 'OK: %s\n' "$*"
}

exe() {
    printf 'RUN:'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

exe_silent() {
    "$@" >/dev/null 2>&1
}

select_flathub_mirror() {
    local choice=1
    local -a names=(SJTU USTC Official)
    local -a urls=(
        'https://mirror.sjtu.edu.cn/flathub'
        'https://mirrors.ustc.edu.cn/flathub'
        'https://dl.flathub.org/repo/'
    )

    if [ "${SHORIN_MODE:-install}" = install ] && [ -t 0 ]; then
        printf 'Flathub mirror: [1] SJTU [2] USTC [3] Official: '
        read -r -t 60 choice || choice=1
    fi
    [[ "$choice" =~ ^[1-3]$ ]] || choice=1
    log "Using Flathub mirror: ${names[$((choice - 1))]}"
    flatpak remote-modify --system flathub --url="${urls[$((choice - 1))]}"
}

ask_continue() {
    local reason=$1 choice=Y

    WARN_COUNT=$((WARN_COUNT + 1))
    WARN_SUMMARY+=("$reason")
    warn "$reason"
    if [ -t 0 ]; then
        read -r -t 30 -p 'Continue anyway? [Y/n]: ' choice || choice=Y
    fi
    if [[ "${choice:-Y}" =~ ^[Nn]$ ]]; then
        if declare -F _on_abort >/dev/null 2>&1; then
            _on_abort "$reason"
        else
            return 1
        fi
    fi
}

print_warn_summary() {
    local item
    [ "$WARN_COUNT" -eq 0 ] && return 0
    warn "Completed with $WARN_COUNT warning(s):"
    for item in "${WARN_SUMMARY[@]}"; do
        warn "$item"
    done
}
