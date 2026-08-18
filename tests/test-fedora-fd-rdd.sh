#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
HOME_DIR="$TEST_DIR/home"
TARGET_USER=$(id -un)
mkdir -p "$BIN_DIR" "$HOME_DIR"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
export SHORIN_ROOT="$ROOT_DIR" TARGET_USER HOME_DIR
export PATH="$BIN_DIR:$PATH"

cat > "$BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$BIN_DIR/cargo"

cat > "$BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
commit=44b60573129c67f4471fa70f21b4a0b70bc1fec8
repo=https://github.com/awei807-wei/vcp-fd-rdd.git
mode=${FEDORA_TEST_GIT_MODE:-success}
printf '%s\n' "$*" >> "${FEDORA_TEST_GIT_LOG:?}"
if [ "${1:-}" = clone ]; then
    [ "$mode" != clone-fail ] || exit 1
    destination=${3:?}
    mkdir -p "$destination/.git" "$destination/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$destination/scripts/install.sh"
    chmod 755 "$destination/scripts/install.sh"
    exit 0
fi
if [ "${1:-}" = -C ]; then
    checkout=${2:?}
    shift 2
    case "${1:-}" in
        remote)
            printf '%s\n' "$repo"
            ;;
        checkout)
            [ "$mode" != checkout-fail ] || exit 1
            printf '%s\n' "$commit" > "$checkout/.checked-out"
            ;;
        rev-parse)
            [ -f "$checkout/.checked-out" ] && printf '%s\n' "$commit" || exit 1
            ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exit 1
EOF
chmod 755 "$BIN_DIR/git"
export FEDORA_TEST_GIT_LOG="$TEST_DIR/git.log"

source "$ROOT_DIR/scripts/lib/core.sh"
require_writable_mode() { return 0; }
fedora_application_target_satisfied() { return 0; }
runuser() {
    [ "${1:-}" = -u ] && shift 2
    [ "${1:-}" = -- ] && shift
    [ "${1:-}" = env ] && shift
    while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do shift; done
    "$@"
}

source_dir=$(fedora_fd_rdd_source_dir "$HOME_DIR")
export FEDORA_TEST_GIT_MODE=clone-fail
status=0
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'fd-rdd clone failure must be reported as pending'
[ ! -e "$source_dir" ] || fail 'failed fd-rdd clone must not publish a cache'
if find "$HOME_DIR/.local/src" -maxdepth 1 -name '.vcp-fd-rdd.*' -print -quit |
    grep -q .; then
    fail 'failed fd-rdd clone must clean its temporary staging directory'
fi

export FEDORA_TEST_GIT_MODE=success
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" ||
    fail 'fd-rdd retry must converge after a transient clone failure'
[ -x "$source_dir/scripts/install.sh" ] ||
    fail 'successful fd-rdd retry must publish the verified source cache'

printf 'old-cache\n' > "$source_dir/old-marker"
export FEDORA_TEST_GIT_MODE=checkout-fail
status=0
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'fd-rdd checkout failure must be reported as pending'
[ "$(< "$source_dir/old-marker")" = old-cache ] ||
    fail 'fd-rdd checkout failure must preserve the previous cache'
if find "$HOME_DIR/.local/src" -maxdepth 1 -name '.vcp-fd-rdd.*' -print -quit |
    grep -q .; then
    fail 'failed fd-rdd checkout must clean its temporary staging directory'
fi

printf 'PASS: Fedora fd-rdd target-user cargo, staged clone, retry, and rollback contract\n'
