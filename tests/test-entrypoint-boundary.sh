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

assert_entrypoint_size
assert_no_implementation_commands
assert_main_guard
assert_source_safe

printf 'PASS: entrypoint boundary contract\n'
