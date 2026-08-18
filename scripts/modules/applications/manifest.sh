#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

application_manifest_metadata_path() {
    printf '%s\n' "${1:-$APPLICATION_MANIFEST}.meta"
}

application_manifest_has_legacy_marker() {
    local manifest=${1:-$APPLICATION_MANIFEST}

    [ -f "$manifest" ] &&
        grep -Fqx '# Migrated from legacy installed state.' "$manifest"
}

application_manifest_hash() {
    local manifest=${1:-$APPLICATION_MANIFEST}

    [ -f "$manifest" ] || return 1
    sha256sum "$manifest" | awk '{ print $1 }'
}

application_source_hash() {
    local source=${1:-$APPLICATION_SOURCE_LIST}

    [ -f "$source" ] || return 1
    sha256sum "$source" | awk '{ print $1 }'
}

application_manifest_metadata_present() {
    local manifest=${1:-$APPLICATION_MANIFEST}
    local metadata

    metadata=$(application_manifest_metadata_path "$manifest")
    [ -s "$metadata" ]
}

application_manifest_metadata_value() {
    local key=$1 manifest=${2:-$APPLICATION_MANIFEST} metadata

    metadata=$(application_manifest_metadata_path "$manifest")
    [ -f "$metadata" ] || return 1
    awk -F= -v wanted="$key" '
        $1 == wanted { print substr($0, index($0, "=") + 1); found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$metadata"
}

write_application_manifest_metadata() {
    local manifest=${1:-$APPLICATION_MANIFEST}
    local source=${2:-$APPLICATION_SOURCE_LIST}
    local mode=${3:-selected}
    local metadata manifest_hash source_hash metadata_tmp metadata_dir

    require_writable_mode || return
    [ -f "$manifest" ] && [ -r "$manifest" ] || {
        error "Cannot record application manifest metadata: $manifest"
        return 1
    }
    source_hash=$(application_source_hash "$source") || {
        error "Cannot record application source revision: $source"
        return 1
    }
    manifest_hash=$(application_manifest_hash "$manifest") || return 1
    metadata=$(application_manifest_metadata_path "$manifest")
    metadata_dir=$(dirname "$metadata")
    install -d -m 755 "$metadata_dir"
    metadata_tmp=$(mktemp "$metadata_dir/.applications.list.meta.XXXXXX")
    cat > "$metadata_tmp" <<EOF
schema=2
source=$source
source_sha256=$source_hash
source_revision=$source_hash
provider_revision=$APPLICATION_PROVIDER_REVISION
manifest_hash=$manifest_hash
manifest_sha256=$manifest_hash
mode=$mode
EOF
    if ! install_if_changed "$metadata_tmp" "$metadata" 644; then
        rm -f "$metadata_tmp"
        return 1
    fi
    rm -f "$metadata_tmp"
}

application_manifest_metadata_status() {
    local phase=${1:-check} manifest=${2:-$APPLICATION_MANIFEST}
    local metadata schema mode recorded_hash actual_hash recorded_source
    local source_hash source_revision provider_revision manifest_sha256

    metadata=$(application_manifest_metadata_path "$manifest")
    [ -s "$metadata" ] || {
        application_manifest_has_legacy_marker "$manifest" && return 10
        return 0
    }
    schema=$(application_manifest_metadata_value schema "$manifest" || true)
    [ "$schema" = 2 ] || return 1
    mode=$(application_manifest_metadata_value mode "$manifest" || true)
    case "$mode" in migrated|selected) ;; *) return 1 ;; esac
    recorded_hash=$(application_manifest_metadata_value manifest_hash "$manifest" || true)
    manifest_sha256=$(application_manifest_metadata_value manifest_sha256 "$manifest" || true)
    [ -n "$recorded_hash" ] && [ "$recorded_hash" = "$manifest_sha256" ] || return 1
    actual_hash=$(application_manifest_hash "$manifest" || true)
    [ -n "$recorded_hash" ] && [ "$recorded_hash" = "$actual_hash" ] || return 10
    recorded_source=$(application_manifest_metadata_value source "$manifest" || true)
    source_hash=$(application_manifest_metadata_value source_sha256 "$manifest" || true)
    source_revision=$(application_manifest_metadata_value source_revision "$manifest" || true)
    provider_revision=$(application_manifest_metadata_value provider_revision "$manifest" || true)
    [ -n "$recorded_source" ] && [ -n "$source_hash" ] &&
        [ "$source_hash" = "$source_revision" ] || return 1
    [ "$provider_revision" = "$APPLICATION_PROVIDER_REVISION" ] || return 11
    if [ -f "$recorded_source" ]; then
        [ "$(application_source_hash "$recorded_source")" = "$source_hash" ] || return 11
    fi
    return 0
}

application_entries_from_file() {
    local file=$1

    [ -f "$file" ] && [ -r "$file" ] || return 2
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            sub(/[[:space:]]+#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (tolower($0) == "lazyvim") $0="lazyvim"
            if (length) print
        }
    ' "$file"
}

application_manifest_entries() {
    application_entries_from_file "$APPLICATION_MANIFEST"
}

collect_legacy_application_targets() {
    local source_file=$1 entry

    while IFS= read -r entry; do
        application_entry_is_valid "$entry" || {
            error "Invalid application entry in $source_file: $entry"
            return 1
        }
        application_entry_detected "$entry" && printf '%s\n' "$entry"
    done < <(application_entries_from_file "$source_file")
    return 0
}

migrate_marked_legacy_application_manifest() {
    local source_file=$1 destination=${2:-$APPLICATION_MANIFEST}
    local metadata staged_manifest source_entry existing_entries
    local destination_dir backup_path rollback_status
    local -A existing=()

    require_writable_mode || return
    [ -f "$destination" ] && [ -r "$destination" ] || return 1
    application_manifest_has_legacy_marker "$destination" || return "$RC_SKIPPED"
    metadata=$(application_manifest_metadata_path "$destination")
    application_manifest_metadata_present "$destination" && return "$RC_SKIPPED"
    [ -f "$source_file" ] && [ -r "$source_file" ] ||
        die "Application source list is not readable: $source_file"

    if ! existing_entries=$(application_entries_from_file "$destination"); then
        error "Application manifest is not readable: $destination"
        return 1
    fi
    while IFS= read -r source_entry; do
        [ -n "$source_entry" ] || continue
        existing["$source_entry"]=1
    done <<< "$existing_entries"

    destination_dir=$(dirname "$destination")
    install -d -m 755 "$destination_dir"
    if ! backup_path=$(mktemp "${destination}.bak.XXXXXX"); then
        error "Unable to create a unique legacy manifest backup: $destination"
        return 1
    fi
    if ! cp -a -- "$destination" "$backup_path"; then
        rm -f -- "$backup_path"
        error "Unable to back up legacy application manifest: $destination"
        return 1
    fi
    staged_manifest=$(mktemp "$destination_dir/.applications.list.XXXXXX")
    if ! cp -a -- "$destination" "$staged_manifest"; then
        rm -f -- "$staged_manifest" "$backup_path"
        error "Unable to stage legacy application manifest: $destination"
        return 1
    fi
    while IFS= read -r source_entry; do
        [ -n "$source_entry" ] || continue
        if [ -z "${existing[$source_entry]:-}" ]; then
            printf '%s\n' "$source_entry" >> "$staged_manifest"
            existing["$source_entry"]=1
        fi
    done < <(application_entries_from_file "$source_file")

    if ! install_if_changed "$staged_manifest" "$destination" 644; then
        rm -f -- "$staged_manifest"
        return 1
    fi
    rm -f -- "$staged_manifest"
    if ! write_application_manifest_metadata "$destination" "$source_file" migrated; then
        if cp -a -- "$backup_path" "$destination"; then
            :
        else
            rollback_status=$?
            error "Legacy application manifest rollback failed: backup=$backup_path destination=$destination status=$rollback_status"
            return 1
        fi
        if rm -f -- "$metadata"; then
            :
        else
            rollback_status=$?
            error "Legacy application metadata cleanup failed after rollback: $metadata status=$rollback_status"
            return 1
        fi
        error "Legacy application manifest migration rolled back after metadata write failure: $destination"
        return 1
    fi
    log "Adopted legacy application manifest additions without removing user entries: $destination"
}

migrate_legacy_application_manifest() {
    local source_file=$1 destination=${2:-$APPLICATION_MANIFEST}
    local temporary detected

    require_writable_mode || return
    [ -f "$source_file" ] && [ -r "$source_file" ] ||
        die "Application source list is not readable: $source_file"
    if [ -f "$destination" ] &&
        application_manifest_has_legacy_marker "$destination" &&
        ! application_manifest_metadata_present "$destination"; then
        migrate_marked_legacy_application_manifest "$source_file" "$destination"
        return
    fi
    if ! detected=$(collect_legacy_application_targets "$source_file" |
        awk '!seen[$0]++'); then
        return 1
    fi
    if [ -z "$detected" ]; then
        warn 'No installed application targets were detected; refusing to declare an empty manifest. Run install mode to select applications.'
        return "$RC_SKIPPED"
    fi
    install -d -m 755 "$(dirname "$destination")"
    temporary=$(mktemp)
    {
        printf '# Migrated from legacy installed state.\n'
        printf '%s\n' "$detected"
    } > "$temporary"
    if ! install_if_changed "$temporary" "$destination" 644; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    write_application_manifest_metadata "$destination" "$source_file" migrated
}
