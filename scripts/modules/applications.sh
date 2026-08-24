#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/applications/targets.sh"

APPLICATION_SOURCE_LIST=${APPLICATION_SOURCE_LIST:-$SHORIN_ROOT/common-applist.txt}
export APPLICATION_SOURCE_LIST

applications_inspect() {
    local phase=$1 entry manifest_entries pending_status=0
    local metadata_status=0 pending_reason intent_state intent_status=0

    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_inspection_failed target-user-context
        return
    fi
    if application_manifest_metadata_present "$APPLICATION_MANIFEST"; then
        intent_state=$(application_selection_intent_state \
            "$APPLICATION_MANIFEST" "$APPLICATION_SOURCE_LIST") ||
            intent_status=$?
        if [ "$intent_status" -eq 0 ] && [ "$intent_state" = selected-all ]; then
            if [ "$phase" = check ]; then
                module_drift application-selection-intent-commit-cleanup
            else
                module_verify_failed application-selection-intent-commit-cleanup
            fi
            return 0
        fi
        intent_status=0
        intent_state=''
    fi
    if [ ! -s "$APPLICATION_MANIFEST" ] ||
        ! application_manifest_metadata_present "$APPLICATION_MANIFEST"; then
        intent_state=$(application_selection_intent_state \
            "$APPLICATION_MANIFEST" "$APPLICATION_SOURCE_LIST") ||
            intent_status=$?
        case "$intent_status:$intent_state" in
            0:pending-selection)
                if [ "$phase" = check ]; then
                    module_drift application-selection-required
                else
                    module_skip application-selection-required
                fi
                return 0
                ;;
            0:selected-all)
                if [ "$phase" = check ]; then
                    module_drift application-manifest-commit-required
                else
                    module_skip application-manifest-commit-required
                fi
                return 0
                ;;
            0:declined)
                module_skip application-selection-declined
                return 0
                ;;
            1:) ;;
            *)
                if [ "$phase" = check ]; then
                    module_inspection_failed application-selection-intent-invalid
                else
                    module_verify_failed application-selection-intent-invalid
                fi
                return 0
                ;;
        esac
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
    application_manifest_metadata_status "$phase" "$APPLICATION_MANIFEST" ||
        metadata_status=$?
    case "$metadata_status" in
        0) ;;
        10)
            if [ "$phase" = check ]; then
                module_drift application-manifest-drift-adopt-required
            else
                module_verify_failed application-manifest-drift-adopt-required
            fi
            ;;
        11)
            if [ "$phase" = check ]; then
                module_drift application-source-revision-drift-adopt-required
            else
                module_verify_failed application-source-revision-drift-adopt-required
            fi
            ;;
        12)
            warn 'Application manifest has no metadata or exact legacy marker; refusing implicit adoption.'
            warn 'To adopt it once, run: sudo env SHORIN_ADOPT_LEGACY_APPLICATIONS=1 bash install.sh repair --distro fedora --user <user> base applications'
            if [ "$phase" = check ]; then
                module_drift application-manifest-legacy-unmarked
            else
                module_verify_failed application-manifest-legacy-unmarked
            fi
            ;;
        *)
            if [ "$phase" = check ]; then
                module_inspection_failed application-manifest-metadata-invalid
            else
                module_verify_failed application-manifest-metadata-invalid
            fi
            ;;
    esac
    # Metadata drift means the manifest is not authoritative yet.  Validate
    # only its syntax, then stop before probing untrusted/custom targets.  A
    # state probe can return an inspection error for a legacy custom entry and
    # would otherwise block the explicitly authorized adoption path.
    if [ "$metadata_status" -ne 0 ]; then
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
                break
            fi
        done <<< "$manifest_entries"
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
                    pending_reason=${FEDORA_APPLICATION_PENDING_REASON:-reason-unavailable}
                    if [ "$phase" = check ]; then
                        # A missing handoff artifact must trigger apply so
                        # other application targets still converge. The apply
                        # phase records this target as pending and skips only
                        # the optional applications module verification.
                        warn "Application target pending: $entry ($pending_reason)"
                        module_drift "application-pending:$entry"
                    else
                        warn "Application target pending: $entry ($pending_reason)"
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
    local status=0 manifest_entries migrate_status=0 intent_state intent_status=0

    if application_manifest_metadata_present "$APPLICATION_MANIFEST"; then
        intent_state=$(application_selection_intent_state \
            "$APPLICATION_MANIFEST" "$APPLICATION_SOURCE_LIST") ||
            intent_status=$?
        if [ "$intent_status" -eq 0 ] && [ "$intent_state" = selected-all ]; then
            clear_application_selection_intent "$APPLICATION_MANIFEST"
            return
        fi
        intent_status=0
        intent_state=''
    fi

    if [ "${SHORIN_MODE:-install}" = repair ] &&
        ! application_manifest_metadata_present "$APPLICATION_MANIFEST"; then
        intent_state=$(application_selection_intent_state \
            "$APPLICATION_MANIFEST" "$APPLICATION_SOURCE_LIST") ||
            intent_status=$?
        case "$intent_status:$intent_state" in
            0:pending-selection)
                if [ ! -t 0 ]; then
                    warn 'Application selection is still pending; rerun repair from a terminal to choose targets.'
                    module_skip application-selection-required
                    return 0
                fi
                SHORIN_APPLICATION_SELECTION_REQUIRED=1 \
                    bash "$SHORIN_ROOT/scripts/modules/applications/apply.sh" ||
                    status=$?
                case "$status" in
                    0) return 0 ;;
                    "$RC_SKIPPED")
                        module_skip application-pending
                        return 0
                        ;;
                    *) return "$status" ;;
                esac
                ;;
            0:selected-all)
                initialize_default_application_manifest \
                    "$APPLICATION_SOURCE_LIST" "$APPLICATION_MANIFEST" || return
                ;;
            0:declined)
                module_skip application-selection-declined
                return 0
                ;;
            1:) ;;
            *)
                error 'Application selection intent is invalid; refusing installed-state migration.'
                return 1
                ;;
        esac
    fi

    if [ "${SHORIN_MODE:-install}" = repair ] &&
        [ -f "$APPLICATION_MANIFEST" ] &&
        application_manifest_has_legacy_marker "$APPLICATION_MANIFEST" &&
        ! application_manifest_metadata_present "$APPLICATION_MANIFEST"; then
        log "Adopting additions from the current application source list without removing user entries..."
        migrate_marked_legacy_application_manifest \
            "$APPLICATION_SOURCE_LIST" "$APPLICATION_MANIFEST" ||
            migrate_status=$?
        [ "$migrate_status" -eq 0 ] || return "$migrate_status"
    elif [ "${SHORIN_MODE:-install}" = repair ] &&
        application_manifest_has_entries "$APPLICATION_MANIFEST" &&
        ! application_manifest_metadata_present "$APPLICATION_MANIFEST" &&
        ! application_manifest_has_legacy_marker "$APPLICATION_MANIFEST"; then
        if [ "${SHORIN_ADOPT_LEGACY_APPLICATIONS:-}" != 1 ]; then
            warn 'Application manifest has no metadata or exact legacy marker; refusing implicit adoption.'
            warn 'To adopt it once, run: sudo env SHORIN_ADOPT_LEGACY_APPLICATIONS=1 bash install.sh repair --distro fedora --user <user> base applications'
            module_skip application-manifest-legacy-unmarked
            return 0
        fi
        log 'Adopting additions from the unmarked legacy application manifest without removing user entries...'
        migrate_unmarked_legacy_application_manifest \
            "$APPLICATION_SOURCE_LIST" "$APPLICATION_MANIFEST" ||
            migrate_status=$?
        [ "$migrate_status" -eq 0 ] || return "$migrate_status"
    elif [ "${SHORIN_MODE:-install}" = repair ] &&
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
