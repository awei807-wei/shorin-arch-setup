#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENTRYPOINT="$ROOT_DIR/install.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_entrypoint_size() {
    local line_count
    line_count=$(wc -l < "$ENTRYPOINT")
    [ "$line_count" -le 150 ] ||
        fail "install.sh must stay at or below 150 lines (actual=$line_count)"
}

assert_no_implementation_commands() {
    local command
    local executable_source

    executable_source=$(awk '
        /^[[:space:]]*#/ { next }
        { print }
    ' "$ENTRYPOINT")

    for command in pacman systemctl sed cp; do
        if grep -Eq "(^|[;&|()[:space:]])${command}([[:space:]]|$)" \
            <<< "$executable_source"; then
            fail "install.sh must not invoke implementation command: $command"
        fi
    done
}

assert_source_safe() {
    local output

    if ! output=$(ENTRYPOINT="$ENTRYPOINT" bash -Eeuo pipefail -c '
        source "$ENTRYPOINT"
        declare -F main >/dev/null
    ' 2>&1); then
        printf '%s\n' "$output" >&2
        fail 'install.sh must be source-safe and expose main'
    fi

    [ -z "$output" ] ||
        fail "sourcing install.sh must not produce output: $output"
}

assert_main_guard() {
    grep -Eq '\[\[[[:space:]]+"?\$\{BASH_SOURCE\[0\]\}"?[[:space:]]+==[[:space:]]+"?\$0"?[[:space:]]+\]\]' \
        "$ENTRYPOINT" || fail 'install.sh must guard main with BASH_SOURCE[0] == $0'
}

assert_distro_option_is_documented() {
    local output

    output=$(ENTRYPOINT="$ENTRYPOINT" bash -Eeuo pipefail -c '
        source "$ENTRYPOINT"
        usage
    ')
    grep -Fq -- '--distro NAME' <<< "$output" ||
        fail 'install help must document explicit Arch/Fedora selection'
}

assert_selected_grub_is_required() {
    local result

    result=$(ENTRYPOINT="$ENTRYPOINT" bash -Eeuo pipefail -c '
        source "$ENTRYPOINT"
        parse_args verify grub
        reset_run_state
        configure_modules
        record_module_failure grub verify rc=1
        derive_final_status
        printf "%s:%s\n" "$(module_policy grub)" "$FINAL_STATUS"
    ')
    [ "$result" = required:FAILED ] ||
        fail "a selected GRUB verification failure must be fatal (actual=$result)"
}

assert_invalid_terminal_is_normalized() {
    local output

    output=$(TERM=xterm-kitty ENTRYPOINT="$ENTRYPOINT" bash -Eeuo pipefail -c '
        source "$ENTRYPOINT"
        infocmp() { [ "${1:-}" = xterm-256color ]; }
        preflight_readonly repair
        printf "TERM=%s\n" "$TERM"
    ' 2>&1)
    grep -Fq \
        'WARNING: TERM=xterm-kitty has no usable terminfo; using TERM=xterm-256color for this run.' \
        <<< "$output" || fail "invalid TERM fallback must emit a diagnostic: $output"
    grep -Fqx 'TERM=xterm-256color' <<< "$output" ||
        fail "invalid TERM must fall back before module execution: $output"
}

assert_valid_terminal_is_preserved() {
    local output

    output=$(TERM=xterm-kitty ENTRYPOINT="$ENTRYPOINT" bash -Eeuo pipefail -c '
        source "$ENTRYPOINT"
        infocmp() { [ "${1:-}" = xterm-kitty ]; }
        normalize_terminal_environment
        printf "%s\n" "$TERM"
    ' 2>&1)
    [ "$output" = xterm-kitty ] ||
        fail "a valid inherited TERM must be preserved without warnings: $output"
}

assert_entrypoint_size
assert_no_implementation_commands
assert_main_guard
assert_distro_option_is_documented
assert_source_safe
assert_selected_grub_is_required
assert_invalid_terminal_is_normalized
assert_valid_terminal_is_preserved

printf 'PASS: entrypoint boundary contract\n'
