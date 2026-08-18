#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

FEDORA_FD_RDD_REPO_URL=https://github.com/awei807-wei/vcp-fd-rdd.git
FEDORA_FD_RDD_COMMIT=44b60573129c67f4471fa70f21b4a0b70bc1fec8

fedora_fd_rdd_source_dir() {
    local home=${1:-${HOME_DIR:-}}

    printf '%s\n' "$home/.local/src/vcp-fd-rdd"
}

fedora_fd_rdd_binary_path() {
    local home=${1:-${HOME_DIR:-}}

    printf '%s\n' "$home/.vcp/bin/fd-rdd"
}

fedora_fd_rdd_local_bin_dir() {
    local home=${1:-${HOME_DIR:-}}

    printf '%s\n' "$home/.local/bin"
}

fedora_fd_rdd_local_link_path() {
    local home=${1:-${HOME_DIR:-}}

    printf '%s\n' "$(fedora_fd_rdd_local_bin_dir "$home")/fd-rdd"
}

fedora_fd_rdd_local_link_target() {
    printf '%s\n' '../../.vcp/bin/fd-rdd'
}

fedora_fd_rdd_link_target_matches() {
    local home=$1 link target resolved expected

    link=$(fedora_fd_rdd_local_link_path "$home")
    target=$(fedora_fd_rdd_binary_path "$home")
    [ -L "$link" ] || return 1
    expected=$(readlink -- "$link") || return 1
    case "$expected" in
        "$target"|../../.vcp/bin/fd-rdd) ;;
        *) return 1 ;;
    esac
    resolved=$(readlink -f -- "$link" 2>/dev/null) || return 1
    [ "$resolved" = "$(readlink -f -- "$target" 2>/dev/null)" ]
}

fedora_fd_rdd_link_satisfied() {
    local user=$1 home=$2 link parent binary group owner parent_owner

    [ -n "$user" ] && [ -n "$home" ] || return 2
    binary=$(fedora_fd_rdd_binary_path "$home")
    link=$(fedora_fd_rdd_local_link_path "$home")
    parent=$(fedora_fd_rdd_local_bin_dir "$home")
    [ -x "$binary" ] && [ ! -L "$binary" ] || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    fedora_fd_rdd_link_target_matches "$home" || return 1
    group=$(id -gn "$user" 2>/dev/null) || return 2
    owner=$(stat -c '%U:%G' "$link" 2>/dev/null) || return 2
    parent_owner=$(stat -c '%U:%G' "$parent" 2>/dev/null) || return 2
    [ "$owner" = "$user:$group" ] && [ "$parent_owner" = "$user:$group" ]
}

fedora_fd_rdd_ensure_local_link() {
    local user=$1 home=$2 group parent link binary owner expected

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || {
        error 'fd-rdd link convergence requires a target user and home.'
        return 1
    }
    group=$(id -gn "$user" 2>/dev/null) || {
        error "Unable to resolve the primary group for target user $user."
        return 1
    }
    parent=$(fedora_fd_rdd_local_bin_dir "$home")
    link=$(fedora_fd_rdd_local_link_path "$home")
    binary=$(fedora_fd_rdd_binary_path "$home")
    [ -x "$binary" ] && [ ! -L "$binary" ] || {
        error "The official fd-rdd binary is missing or unsafe: $binary"
        return 1
    }
    # Never follow a user-controlled directory symlink while preparing the
    # compatibility entry point.
    [ ! -L "$home/.local" ] && [ ! -L "$parent" ] || {
        error "Refusing fd-rdd link convergence through a symlinked parent: $parent"
        return 1
    }
    install -d -m 755 -o "$user" -g "$group" "$parent" || {
        error "Unable to prepare the target-user fd-rdd directory: $parent"
        return 1
    }
    if [ -e "$link" ] || [ -L "$link" ]; then
        if [ ! -L "$link" ]; then
            error "Refusing to replace the user-owned fd-rdd path: $link"
            return 1
        fi
        fedora_fd_rdd_link_target_matches "$home" || {
            expected=$(readlink -- "$link" 2>/dev/null || printf '<unreadable>')
            error "Refusing fd-rdd symlink with an unexpected target: $link -> $expected"
            return 1
        }
        owner=$(stat -c '%U:%G' "$link" 2>/dev/null) || {
            error "Unable to inspect fd-rdd symlink ownership: $link"
            return 1
        }
        if [ "$owner" != "$user:$group" ]; then
            chown -h "$user:$group" "$link" || {
                error "Unable to assign fd-rdd symlink ownership: $link"
                return 1
            }
        fi
    else
        fedora_fd_rdd_as_user "$user" "$home" ln -s \
            "$(fedora_fd_rdd_local_link_target)" "$link" || {
            error "Unable to create the target-user fd-rdd symlink: $link"
            return 1
        }
    fi
    fedora_fd_rdd_link_satisfied "$user" "$home"
}

fedora_fd_rdd_binary_satisfied() {
    local home=${1:-${HOME_DIR:-}} user=${2:-${TARGET_USER:-}}

    # The official installer writes ~/.vcp/bin.  The managed ~/.local/bin
    # symlink is the stable Bash/Fish entry point and is part of the target
    # contract; an unrelated PATH command must never satisfy this target.
    fedora_fd_rdd_link_satisfied "$user" "$home"
}

fedora_fd_rdd_target_path() {
    local home=$1

    # 官方安装器以目标用户身份运行，不能依赖交互式 shell 继承 PATH。
    # 固定工具链目录，避免把 root 或测试仓库的 PATH 带入安装过程。
    printf '%s\n' "$home/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
}

fedora_fd_rdd_as_user() {
    local user=$1 home=$2
    shift 2
    runuser -u "$user" -- env HOME="$home" \
        PATH="$(fedora_fd_rdd_target_path "$home")" "$@"
}

fedora_fd_rdd_run_official_installer() {
    local user=$1 home=$2 source_dir=$3 script=$4

    # install.sh 依赖仓库工作目录；在受控的目标用户子 shell 中先进入
    # 已验证的 checkout，再执行脚本，不信任脚本自行切换目录。
    fedora_fd_rdd_as_user "$user" "$home" bash -c \
        'cd -- "$1" && exec bash "$2"' \
        fd-rdd-install "$source_dir" "$script"
}

fedora_fd_rdd_cleanup() {
    local path=${1:-}

    [ -n "$path" ] && [ -e "$path" ] || return 0
    find "$path" -depth -delete
}

fedora_fd_rdd_cargo_available() {
    local user=$1 home=$2

    fedora_fd_rdd_as_user "$user" "$home" \
        bash -c 'command -v cargo >/dev/null 2>&1'
}

fedora_install_fd_rdd() {
    local user=$1 home=$2 script source_dir current_head
    local staging_root='' staged_checkout remote previous_dir
    local parent_dir

    require_writable_mode || return
    # A previous official install only needs the compatibility entry point
    # converged; do not reclone or rerun the upstream installer.
    if [ -x "$(fedora_fd_rdd_binary_path "$home")" ] &&
        [ ! -L "$(fedora_fd_rdd_binary_path "$home")" ]; then
        fedora_fd_rdd_ensure_local_link "$user" "$home" || return
        fedora_application_target_satisfied fd-rdd-git "$user" "$home"
        return
    fi
    if [ -n "${FEDORA_FD_RDD_INSTALL_SCRIPT:-}" ] &&
        [ -r "$FEDORA_FD_RDD_INSTALL_SCRIPT" ]; then
        script=$FEDORA_FD_RDD_INSTALL_SCRIPT
        grep -q '^#!' "$script" || {
            error 'Local fd-rdd installer did not contain a shebang.'
            return 1
        }
        if ! fedora_fd_rdd_as_user "$user" "$home" bash "$script"; then
            error 'The official fd-rdd install.sh failed for the target user.'
            return 1
        fi
        fedora_fd_rdd_ensure_local_link "$user" "$home" || return
        fedora_application_target_satisfied fd-rdd-git "$user" "$home"
        return
    fi

    command -v git >/dev/null 2>&1 || {
        FEDORA_APPLICATION_PENDING_REASON="official-source-requires-git:repo=$FEDORA_FD_RDD_REPO_URL:commit=$FEDORA_FD_RDD_COMMIT"
        warn 'Pending Fedora target: fd-rdd requires git to fetch the pinned official source.'
        warn "Install git or provide FEDORA_FD_RDD_INSTALL_SCRIPT; source is $FEDORA_FD_RDD_REPO_URL at commit $FEDORA_FD_RDD_COMMIT."
        return "$RC_SKIPPED"
    }
    command -v runuser >/dev/null 2>&1 || {
        FEDORA_APPLICATION_PENDING_REASON='target-user-install-requires-runuser'
        warn 'Pending Fedora target: fd-rdd requires runuser for target-user installation.'
        return "$RC_SKIPPED"
    }
    fedora_fd_rdd_cargo_available "$user" "$home" || {
        FEDORA_APPLICATION_PENDING_REASON='target-user-cargo-missing:fd-rdd'
        warn 'Pending Fedora target: fd-rdd requires cargo in the target-user environment.'
        return "$RC_SKIPPED"
    }
    parent_dir="$home/.local/src"
    fedora_fd_rdd_as_user "$user" "$home" mkdir -p "$parent_dir" || return 1
    source_dir=$(fedora_fd_rdd_source_dir "$home")
    if [ -e "$source_dir" ] && [ ! -d "$source_dir/.git" ]; then
        error "Cannot update fd-rdd: $source_dir exists but is not a Git repository."
        return 1
    fi
    # Keep a failed network or checkout attempt out of the controlled cache.
    # RETURN trap cleanup runs for every return path after staging begins.
    trap 'if [ -n "${staging_root:-}" ]; then fedora_fd_rdd_cleanup "$staging_root"; staging_root=""; fi; trap - RETURN' RETURN
    staging_root=$(fedora_fd_rdd_as_user "$user" "$home" \
        mktemp -d "$parent_dir/.vcp-fd-rdd.XXXXXX") || {
        FEDORA_APPLICATION_PENDING_REASON="official-source-staging-failed:repo=$FEDORA_FD_RDD_REPO_URL:commit=$FEDORA_FD_RDD_COMMIT"
        warn 'Pending Fedora target: unable to create a temporary fd-rdd source directory.'
        return "$RC_SKIPPED"
    }
    staged_checkout="$staging_root/checkout"
    if ! fedora_fd_rdd_as_user "$user" "$home" git clone \
        "$FEDORA_FD_RDD_REPO_URL" "$staged_checkout"; then
        FEDORA_APPLICATION_PENDING_REASON="official-source-clone-failed:repo=$FEDORA_FD_RDD_REPO_URL:commit=$FEDORA_FD_RDD_COMMIT"
        warn "Pending Fedora target: unable to clone fd-rdd at commit $FEDORA_FD_RDD_COMMIT."
        return "$RC_SKIPPED"
    fi
    remote=$(fedora_fd_rdd_as_user "$user" "$home" git -C "$staged_checkout" \
        remote get-url origin) || {
        error 'Cannot read the staged fd-rdd origin remote.'
        return 1
    }
    case "$remote" in
        "$FEDORA_FD_RDD_REPO_URL"|https://github.com/awei807-wei/vcp-fd-rdd) ;;
        *) error "Refusing staged fd-rdd checkout with unexpected origin: $remote"; return 1 ;;
    esac
    fedora_fd_rdd_as_user "$user" "$home" git -C "$staged_checkout" \
        checkout --detach "$FEDORA_FD_RDD_COMMIT" || {
        FEDORA_APPLICATION_PENDING_REASON="official-source-commit-unavailable:$FEDORA_FD_RDD_COMMIT"
        warn "Pending Fedora target: fd-rdd commit is unavailable: $FEDORA_FD_RDD_COMMIT"
        return "$RC_SKIPPED"
    }
    current_head=$(fedora_fd_rdd_as_user "$user" "$home" git -C "$staged_checkout" \
        rev-parse HEAD) || return 1
    [ "$current_head" = "$FEDORA_FD_RDD_COMMIT" ] || {
        error "fd-rdd checkout is not pinned to $FEDORA_FD_RDD_COMMIT: $current_head"
        return 1
    }
    script="$staged_checkout/scripts/install.sh"
    [ -r "$script" ] && grep -q '^#!' "$script" || {
        error "Pinned fd-rdd source has no usable scripts/install.sh: $script"
        return 1
    }
    previous_dir=''
    if [ -e "$source_dir" ]; then
        previous_dir=$(fedora_fd_rdd_as_user "$user" "$home" \
            mktemp -d "${source_dir}.previous.XXXXXX")
        fedora_fd_rdd_as_user "$user" "$home" rmdir "$previous_dir"
        if ! fedora_fd_rdd_as_user "$user" "$home" mv \
            "$source_dir" "$previous_dir"; then
            error "Unable to stage the previous fd-rdd cache for replacement: $source_dir"
            return 1
        fi
    fi
    if ! fedora_fd_rdd_as_user "$user" "$home" mv \
        "$staged_checkout" "$source_dir"; then
        if [ -n "$previous_dir" ]; then
            fedora_fd_rdd_as_user "$user" "$home" mv \
                "$previous_dir" "$source_dir" ||
                error "Unable to restore the previous fd-rdd cache: $source_dir"
        fi
        error "Unable to publish the verified fd-rdd source cache: $source_dir"
        return 1
    fi
    if [ -n "$previous_dir" ]; then
        if ! fedora_fd_rdd_cleanup "$previous_dir"; then
            error "Unable to remove the superseded fd-rdd cache: $previous_dir"
            return 1
        fi
        previous_dir='' # The old cache is removed only after the new one is live.
    fi
    if ! fedora_fd_rdd_run_official_installer "$user" "$home" \
        "$source_dir" "$source_dir/scripts/install.sh"; then
        error 'Pinned fd-rdd scripts/install.sh failed for the target user.'
        return 1
    fi
    fedora_fd_rdd_ensure_local_link "$user" "$home" || return
    fedora_application_target_satisfied fd-rdd-git "$user" "$home"
}
