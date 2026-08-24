#!/usr/bin/env bash
set -Eeuo pipefail

# The upstream longshot launcher first looks for a local virtual environment
# that can import OpenCV and NumPy.  Converge that runtime from distribution
# packages so launching a screenshot never invokes the upstream setup.sh or
# downloads unpinned Python wheels.

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_longshot_venv_uses_system_packages() {
    local config="$NIRI_LONGSHOT_VENV_DIR/pyvenv.cfg"

    [ -f "$config" ] && [ ! -L "$config" ] || return 1
    awk -F= '
        /^[[:space:]]*include-system-site-packages[[:space:]]*=/ {
            value=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            count++
            if (tolower(value) == "true") matches++
        }
        END { exit !(count == 1 && matches == 1) }
    ' "$config"
}

niri_longshot_tree_owned_by() {
    local user=$1 uid unexpected

    uid=$(id -u "$user") || return 1
    unexpected=$(find -P "$NIRI_LONGSHOT_VENV_DIR" -xdev \
        ! -uid "$uid" -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ]
}

niri_longshot_python_module_contract() {
    local user=$1 python="$NIRI_LONGSHOT_VENV_DIR/bin/python"

    [ -x "$python" ] || return 1
    niri_run_as_user "$user" env HOME="$HOME_DIR" PYTHONNOUSERSITE=1 \
        "$python" -I -c '
import pathlib
import importlib
import sys

venv = pathlib.Path(sys.argv[1]).resolve()
missing = False
for name in ("cv2", "numpy"):
    try:
        module = importlib.import_module(name)
    except ModuleNotFoundError:
        missing = True
        continue
    source = getattr(module, "__file__", None)
    if not source:
        raise SystemExit(43)
    try:
        pathlib.Path(source).resolve().relative_to(venv)
    except ValueError:
        continue
    raise SystemExit(42)
if missing:
    raise SystemExit(1)
' "$NIRI_LONGSHOT_VENV_DIR"
}

niri_longshot_python_imports() {
    niri_longshot_python_module_contract "$1"
}

niri_longshot_runtime_has_local_shadow() {
    local user=$1 status=0

    niri_longshot_python_module_contract "$user" || status=$?
    [ "$status" -eq 42 ]
}

niri_longshot_runtime_satisfied() {
    local user=${1:-$TARGET_USER}

    [ -n "${NIRI_LONGSHOT_VENV_DIR:-}" ] || return 2
    niri_path_is_safe_no_symlink "$NIRI_LONGSHOT_VENV_DIR" || return 1
    [ -d "$NIRI_LONGSHOT_VENV_DIR" ] &&
        [ ! -L "$NIRI_LONGSHOT_VENV_DIR" ] || return 1
    niri_longshot_venv_uses_system_packages || return 1
    niri_longshot_tree_owned_by "$user" || return 1
    niri_longshot_python_imports "$user"
}

niri_longshot_remove_stage() {
    local stage=$1 parent

    parent=$(dirname "$NIRI_LONGSHOT_VENV_DIR")
    case "$stage" in
        "$parent"/.shorin-longshot-venv.*) ;;
        *) return 1 ;;
    esac
    [ -e "$stage" ] || [ -L "$stage" ] || return 0
    find -P "$stage" -depth -delete
}

niri_longshot_system_python_satisfied() {
    local user=$1 python=$2

    niri_run_as_user "$user" env HOME="$HOME_DIR" PYTHONNOUSERSITE=1 \
        "$python" -I -c 'import cv2, numpy'
}

ensure_niri_longshot_runtime() {
    local user=${1:-$TARGET_USER} parent group python stage=

    require_writable_mode || return
    niri_longshot_runtime_satisfied "$user" && return 0
    [ -n "${NIRI_LONGSHOT_VENV_DIR:-}" ] || return 2
    parent=$(dirname "$NIRI_LONGSHOT_VENV_DIR")
    niri_path_is_safe_no_symlink "$parent" || {
        error "Refusing unsafe longshot runtime parent ($NIRI_PATH_SAFETY_REASON)."
        return 1
    }
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
        error "Longshot script directory is missing or unsafe: $parent"
        return 1
    }
    group=$(id -gn "$user") || return 1
    [ "$(stat -c '%u' "$parent")" -eq "$(id -u "$user")" ] || {
        error "Longshot script directory is not owned by $user: $parent"
        return 1
    }
    python=$(command -v python3) || {
        error 'python3 is required for the longshot runtime.'
        return 1
    }
    niri_longshot_system_python_satisfied "$user" "$python" || {
        error 'Distribution Python cannot import cv2 and numpy for longshot.'
        return 1
    }

    if [ -e "$NIRI_LONGSHOT_VENV_DIR" ] || [ -L "$NIRI_LONGSHOT_VENV_DIR" ]; then
        niri_path_is_safe_no_symlink "$NIRI_LONGSHOT_VENV_DIR" || {
            error "Refusing unsafe longshot virtual environment ($NIRI_PATH_SAFETY_REASON)."
            return 1
        }
        [ -d "$NIRI_LONGSHOT_VENV_DIR" ] &&
            [ ! -L "$NIRI_LONGSHOT_VENV_DIR" ] &&
            [ -f "$NIRI_LONGSHOT_VENV_DIR/pyvenv.cfg" ] &&
            [ ! -L "$NIRI_LONGSHOT_VENV_DIR/pyvenv.cfg" ] || {
                error "Refusing to replace an unrecognized longshot runtime: $NIRI_LONGSHOT_VENV_DIR"
                return 1
            }
        niri_longshot_tree_owned_by "$user" || {
            error "Refusing a longshot runtime not wholly owned by $user."
            return 1
        }
        if niri_longshot_runtime_has_local_shadow "$user"; then
            error "Refusing to modify longshot runtime: local cv2/numpy packages shadow distribution modules in $NIRI_LONGSHOT_VENV_DIR. Remove or relocate those user packages manually."
            return 1
        fi
        niri_run_as_user "$user" env HOME="$HOME_DIR" \
            "$python" -m venv --upgrade --system-site-packages --without-pip \
            "$NIRI_LONGSHOT_VENV_DIR" || return 1
        if ! niri_longshot_runtime_satisfied "$user"; then
            if niri_longshot_runtime_has_local_shadow "$user"; then
                error "Longshot runtime upgrade exposed local cv2/numpy packages that shadow distribution modules; user packages were preserved."
            else
                error 'Longshot virtual environment cannot import distribution cv2 and numpy after its non-network upgrade.'
            fi
            return 1
        fi
        return 0
    fi

    stage=$(niri_run_as_user "$user" mktemp -d \
        "$parent/.shorin-longshot-venv.XXXXXX") || return 1
    if ! niri_run_as_user "$user" rmdir "$stage" ||
        ! niri_run_as_user "$user" env HOME="$HOME_DIR" \
            "$python" -m venv --system-site-packages --without-pip "$stage"; then
        niri_longshot_remove_stage "$stage" || true
        return 1
    fi
    if [ -e "$NIRI_LONGSHOT_VENV_DIR" ] || [ -L "$NIRI_LONGSHOT_VENV_DIR" ] ||
        ! mv -T -- "$stage" "$NIRI_LONGSHOT_VENV_DIR"; then
        niri_longshot_remove_stage "$stage" || true
        return 1
    fi
    chown "$user:$group" "$NIRI_LONGSHOT_VENV_DIR" || return 1
    niri_longshot_runtime_satisfied "$user" || {
        error 'New longshot virtual environment cannot import cv2 and numpy from distribution packages.'
        return 1
    }
}
