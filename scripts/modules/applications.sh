#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/applications/targets.sh"

APPLICATION_SOURCE_LIST=${APPLICATION_SOURCE_LIST:-$SHORIN_ROOT/common-applist.txt}

applications_inspect() {
    local phase=$1 entry manifest_entries pending_status=0

    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_inspection_failed target-user-context
        return
    fi
    if [ ! -s "$APPLICATION_MANIFEST" ]; then
        if [ "$phase" = verify ]; then
            module_skip application-targets-not-declared
        elif [ "${SHORIN_MODE:-install}" = install ]; then
            module_drift application-manifest
        else
            module_drift legacy-application-manifest
        fi
        return 0
    fi
    if ! manifest_entries=$(application_manifest_entries); then
        if [ "$phase" = check ]; then
            module_inspection_failed application-manifest-unreadable
        else
            module_verify_failed application-manifest-unreadable
        fi
        return
    fi
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if ! application_entry_is_valid "$entry"; then
            if [ "$phase" = check ]; then
                module_inspection_failed "application-manifest-invalid:$entry"
            else
                module_verify_failed "application-manifest-invalid:$entry"
            fi
            return
        fi
        if platform_is_fedora && [[ "$entry" == AUR:* ]]; then
            pending_status=0
            fedora_application_target_pending "${entry#AUR:}" \
                "$HOME_DIR" || pending_status=$?
            case "$pending_status" in
                0)
                    if [ "$phase" = check ]; then
                        # A missing handoff artifact must trigger apply so
                        # other application targets still converge. The apply
                        # phase records this target as pending and skips only
                        # the optional applications module verification.
                        module_drift "application-pending:$entry"
                    else
                        module_skip "application-pending:$entry"
                    fi
                    continue
                    ;;
                1) ;;
                *)
                    if [ "$phase" = check ]; then
                        module_inspection_failed \
                            "application-pending-inspection-error:$entry:$pending_status"
                    else
                        module_verify_failed \
                            "application-pending-inspection-error:$entry:$pending_status"
                    fi
                    continue
                    ;;
            esac
        fi
        if [ "$phase" = check ]; then
            module_check_state "application:$entry" \
                application_entry_satisfied "$entry"
            [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
        elif ! application_entry_satisfied "$entry"; then
            module_verify_failed "application:$entry"
        fi
    done <<< "$manifest_entries"

    if [ "$MODULE_RESULT" -eq "$RC_OK" ] &&
        grep -Fqx 'GitHub:niri-clip' <<< "$manifest_entries" &&
        [ ! -S "/run/user/$(id -u "$TARGET_USER")/bus" ]; then
        module_skip user-services-pending-login
    fi
}

applications_check() { applications_inspect check; }

applications_apply() {
    local status=0 manifest_entries migrate_status=0

    if [ "${SHORIN_MODE:-install}" = repair ] &&
        [ ! -s "$APPLICATION_MANIFEST" ]; then
        log "Migrating legacy application targets from current installed state..."
        migrate_legacy_application_manifest \
            "$APPLICATION_SOURCE_LIST" "$APPLICATION_MANIFEST" ||
            migrate_status=$?
        if [ "$migrate_status" -eq "$RC_SKIPPED" ]; then
            module_skip application-targets-undetected
            return 0
        fi
        [ "$migrate_status" -eq 0 ] || return "$migrate_status"
    fi
    if [ "${SHORIN_MODE:-install}" = repair ]; then
        if ! manifest_entries=$(application_manifest_entries); then
            die "Application manifest is not readable: $APPLICATION_MANIFEST"
        fi
        if [ -z "$manifest_entries" ]; then
            warn "The declared application manifest is empty; run install mode to select applications."
            module_skip application-targets-empty
            return 0
        fi
    fi

    bash "$SHORIN_ROOT/scripts/modules/applications/apply.sh" || status=$?
    case "$status" in
        0) return 0 ;;
        "$RC_SKIPPED")
            module_skip application-pending
            return 0
            ;;
        *) return "$status" ;;
    esac
}

applications_verify() { applications_inspect verify; }

module_main applications "$@"
