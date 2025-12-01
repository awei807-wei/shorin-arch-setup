#!/bin/bash

# ==============================================================================
# 00-utils.sh - The Visual Engine & Logger (v3.1)
# ==============================================================================

# --- 0. Global Log Settings ---
export TEMP_LOG_FILE="/tmp/log-shorin-arch-setup.txt"

# Ensure log file exists and is writable
if [ ! -f "$TEMP_LOG_FILE" ]; then
    touch "$TEMP_LOG_FILE"
    chmod 666 "$TEMP_LOG_FILE"
fi

# --- 1. Colors & Styles ---
export NC='\033[0m'
export BOLD='\033[1m'
export DIM='\033[2m'

# Foreground Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[0;37m'

# High Intensity Colors
export H_RED='\033[1;31m'
export H_GREEN='\033[1;32m'
export H_YELLOW='\033[1;33m'
export H_BLUE='\033[1;34m'
export H_PURPLE='\033[1;35m'
export H_CYAN='\033[1;36m'
export H_GRAY='\033[1;30m'

# --- 2. Basic Tools ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${H_RED}❌  Error: Script must be run as root.${NC}"
        exit 1
    fi
}

timestamp() {
    date "+%H:%M:%S"
}

# --- 3. Logging Helper (Write to File) ---
write_log() {
    local level="$1"
    local msg="$2"
    # Remove ANSI escape codes for clean text logging
    local clean_msg=$(echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $clean_msg" >> "$TEMP_LOG_FILE"
}

# --- 4. UI Components ---

section() {
    local step_num="$1"
    local title="$2"
    echo ""
    echo -e "${H_PURPLE}╭──────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_PURPLE}│${NC} ${H_CYAN}${BOLD}$step_num${NC} ${title}"
    echo -e "${H_PURPLE}╰──────────────────────────────────────────────────────────────╯${NC}"
    write_log "SECTION" "$step_num - $title"
}

cmd() {
    echo -e "   ${H_GRAY}$ ${NC}${DIM}$1${NC}"
    write_log "CMD" "$1"
}

info_kv() {
    local key="$1"
    local val="$2"
    local extra="$3"
    printf "   ${H_BLUE}●${NC} %-12s : ${BOLD}%s${NC} ${DIM}%s${NC}\n" "$key" "$val" "$extra"
    write_log "INFO" "$key: $val $extra"
}

log() {
    echo -e "   ${H_BLUE}➜${NC} $1"
    write_log "INFO" "$1"
}

success() {
    echo -e "   ${H_GREEN}✔${NC} ${BOLD}$1${NC}"
    write_log "SUCCESS" "$1"
}

warn() {
    echo -e "   ${H_YELLOW}⚡ WARN:${NC} $1"
    write_log "WARN" "$1"
}

error() {
    echo -e "   ${H_RED}✖ ERROR:${NC} $1"
    write_log "ERROR" "$1"
}

subtask() {
    echo -ne "   ${DIM}├─ $1... ${NC}"
    # Log start of subtask
    # We won't log '...' to file to keep it clean, maybe just the action
}

sub_done() {
    echo -e "${H_GREEN}Done${NC}"
    # No specific file log needed for sub_done usually, unless detailed tracing
}

sub_fail() {
    echo -e "${H_RED}Failed${NC}"
    write_log "ERROR" "Subtask Failed"
}