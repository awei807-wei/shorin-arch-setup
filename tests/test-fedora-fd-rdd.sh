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
mkdir -p "$HOME_DIR/.cargo/bin"
cp "$BIN_DIR/cargo" "$HOME_DIR/.cargo/bin/cargo"

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
    printf 'name = "fd-rdd-fixture"\n' > "$destination/Cargo.toml"
    printf 'fixture\n' > "$destination/.fd-rdd-fixture-marker"
    cat > "$destination/scripts/install.sh" <<'EOF_INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(pwd)" = "$(dirname "$(dirname "$0")")" ]
[ -f Cargo.toml ]
[ -f .fd-rdd-fixture-marker ]
case ":$PATH:" in
    *":$HOME/.cargo/bin:"*) ;;
    *) printf 'missing user cargo path: %s\n' "$PATH" >&2; exit 1 ;;
esac
case ":$PATH:" in
    *":/usr/bin:"*) ;;
    *) printf 'missing /usr/bin: %s\n' "$PATH" >&2; exit 1 ;;
esac
command -v cargo >/dev/null 2>&1
mkdir -p "$HOME/.vcp/bin"
printf '#!/usr/bin/env bash\n' > "$HOME/.vcp/bin/fd-rdd"
chmod 755 "$HOME/.vcp/bin/fd-rdd"
printf '%s\n' "$PATH" > "$HOME/.vcp/fd-rdd-installer.path"
EOF_INSTALLER
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
cp "$BIN_DIR/git" "$HOME_DIR/.cargo/bin/git"
export FEDORA_TEST_GIT_LOG="$TEST_DIR/git.log"

source "$ROOT_DIR/scripts/lib/core.sh"
require_writable_mode() { return 0; }
runuser() {
    local -a env_args=()
    [ "${1:-}" = -u ] && shift 2
    [ "${1:-}" = -- ] && shift
    if [ "${1:-}" = env ]; then
        shift
        while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
            env_args+=("$1")
            shift
        done
        env "${env_args[@]}" "$@"
        return
    fi
    "$@"
}

source_dir=$(fedora_fd_rdd_source_dir "$HOME_DIR")
cd "$TEST_DIR"
export FEDORA_TEST_GIT_MODE=clone-fail
status=0
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'fd-rdd clone failure must be reported as pending'
[ "$FEDORA_APPLICATION_PENDING_REASON" = \
    "official-source-clone-failed:repo=$FEDORA_FD_RDD_REPO_URL:commit=$FEDORA_FD_RDD_COMMIT" ] ||
    fail 'fd-rdd clone failure must retain its pending reason'
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
[ -x "$HOME_DIR/.vcp/bin/fd-rdd" ] ||
    fail 'successful fd-rdd retry must run the installer from the source checkout'
[ -L "$HOME_DIR/.local/bin/fd-rdd" ] ||
    fail 'successful fd-rdd install must publish the ~/.local/bin compatibility symlink'
[ "$(readlink "$HOME_DIR/.local/bin/fd-rdd")" = '../../.vcp/bin/fd-rdd' ] ||
    fail 'fd-rdd compatibility symlink must use the stable relative target'
[ "$(stat -c '%U:%G' "$HOME_DIR/.local/bin")" = \
    "$(id -un):$(id -gn)" ] ||
    fail 'fd-rdd compatibility directory must be owned by the target user'
[ "$(stat -c '%U:%G' "$HOME_DIR/.local/bin/fd-rdd")" = \
    "$(id -un):$(id -gn)" ] ||
    fail 'fd-rdd compatibility symlink must be owned by the target user'
[ "$(< "$HOME_DIR/.vcp/fd-rdd-installer.path")" = \
    "$HOME_DIR/.cargo/bin:/usr/local/bin:/usr/bin:/bin" ] ||
    fail 'fd-rdd installer must receive the explicit target-user PATH'

printf 'old-cache\n' > "$source_dir/old-marker"
rm -f "$HOME_DIR/.vcp/bin/fd-rdd" "$HOME_DIR/.local/bin/fd-rdd"
export FEDORA_TEST_GIT_MODE=checkout-fail
status=0
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'fd-rdd checkout failure must be reported as pending'
[ "$FEDORA_APPLICATION_PENDING_REASON" = \
    "official-source-commit-unavailable:$FEDORA_FD_RDD_COMMIT" ] ||
    fail 'fd-rdd checkout failure must retain its pending reason'
[ "$(< "$source_dir/old-marker")" = old-cache ] ||
    fail 'fd-rdd checkout failure must preserve the previous cache'
if find "$HOME_DIR/.local/src" -maxdepth 1 -name '.vcp-fd-rdd.*' -print -quit |
    grep -q .; then
    fail 'failed fd-rdd checkout must clean its temporary staging directory'
fi

# 官方安装器写入 ~/.vcp/bin/fd-rdd；通过应用目标包装器验证真实路径，并确认目标
# 满足后的第二次运行不会重复执行。
LOCAL_INSTALLER="$TEST_DIR/fd-rdd-install.sh"
LOCAL_INSTALL_CALLS="$TEST_DIR/fd-rdd-install.calls"
cat > "$LOCAL_INSTALLER" <<'EOF_LOCAL_INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'install\n' >> "${FEDORA_TEST_LOCAL_INSTALL_CALLS:?}"
printf '%s\n' "$PATH" > "${FEDORA_TEST_LOCAL_INSTALL_PATH:?}"
mkdir -p "$HOME/.vcp/bin"
printf '#!/usr/bin/env bash\n' > "$HOME/.vcp/bin/fd-rdd"
chmod 755 "$HOME/.vcp/bin/fd-rdd"
EOF_LOCAL_INSTALLER
chmod 755 "$LOCAL_INSTALLER"
export FEDORA_FD_RDD_INSTALL_SCRIPT="$LOCAL_INSTALLER"
export FEDORA_TEST_LOCAL_INSTALL_CALLS="$LOCAL_INSTALL_CALLS"
export FEDORA_TEST_LOCAL_INSTALL_PATH="$TEST_DIR/fd-rdd-install.path"
rm -rf "$HOME_DIR/.vcp" "$HOME_DIR/.local/bin/fd-rdd"
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" ||
    fail 'fd-rdd fake installer must return success'
[ -x "$HOME_DIR/.vcp/bin/fd-rdd" ] ||
    fail 'fd-rdd fake installer must create the official ~/.vcp/bin path'
[ "$(< "$FEDORA_TEST_LOCAL_INSTALL_PATH")" = \
    "$HOME_DIR/.cargo/bin:/usr/local/bin:/usr/bin:/bin" ] ||
    fail 'local fd-rdd installer must receive the explicit target-user PATH'
fedora_install_application_target fd-rdd-git "$TARGET_USER" "$HOME_DIR" ||
    fail 'fd-rdd target must remain successful on an idempotent rerun'
[ "$(wc -l < "$LOCAL_INSTALL_CALLS")" -eq 1 ] ||
    fail 'fd-rdd target must not rerun a satisfied fake installer'
rm -f "$HOME_DIR/.local/bin/fd-rdd"
printf 'user-owned fd-rdd\n' > "$HOME_DIR/.local/bin/fd-rdd"
status=0
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq 1 ] ||
    fail 'fd-rdd must fail closed on an ordinary user-owned file'
[ "$(< "$HOME_DIR/.local/bin/fd-rdd")" = 'user-owned fd-rdd' ] ||
    fail 'fd-rdd conflict handling must preserve the user-owned file'
rm -f "$HOME_DIR/.local/bin/fd-rdd"
ln -s /tmp/unexpected-fd-rdd "$HOME_DIR/.local/bin/fd-rdd"
status=0
fedora_install_fd_rdd "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq 1 ] ||
    fail 'fd-rdd must fail closed on an unexpected symlink target'
[ "$(readlink "$HOME_DIR/.local/bin/fd-rdd")" = /tmp/unexpected-fd-rdd ] ||
    fail 'fd-rdd conflict handling must preserve an unexpected symlink'
rm -f "$HOME_DIR/.local/bin/fd-rdd"
fedora_fd_rdd_ensure_local_link "$TARGET_USER" "$HOME_DIR" ||
    fail 'fd-rdd must converge its compatibility symlink after a preserved conflict'
fedora_application_target_satisfied fd-rdd-git "$TARGET_USER" "$HOME_DIR" ||
    fail 'fd-rdd satisfaction must verify the official binary and compatibility symlink'
rm -rf "$HOME_DIR/.vcp"
cat > "$BIN_DIR/fd-rdd" <<'EOF_PATH_FD_RDD'
#!/usr/bin/env bash
exit 0
EOF_PATH_FD_RDD
chmod 755 "$BIN_DIR/fd-rdd"
if fedora_application_target_satisfied fd-rdd-git "$TARGET_USER" "$HOME_DIR"; then
    fail 'fd-rdd satisfaction must not trust an unrelated PATH command'
fi

printf 'PASS: Fedora fd-rdd target-user cargo, staged clone, retry, and rollback contract\n'
