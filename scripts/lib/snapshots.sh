#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Prints the newest snapshot ID whose description exactly matches the marker.
snapshot_latest_id() {
    local config=$1 marker=$2 output

    output=$(snapper --csvout --separator $'\t' --no-headers -c "$config" \
        list --columns number,description) || return 2
    awk -F '\t' -v marker="$marker" '
        /^[[:space:]]*[0-9]+\t/ {
            id=$1
            description=$2
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", description)
            if (description == marker) latest=id
        }
        END { if (latest != "") print latest; else exit 1 }
    ' <<< "$output"
}

# Prints "ID<TAB>description" for the newest exact or run-scoped marker.
snapshot_latest_record() {
    local config=$1 marker=$2 output

    output=$(snapper --csvout --separator $'\t' --no-headers -c "$config" \
        list --columns number,description) || return 2
    awk -F '\t' -v marker="$marker" '
        /^[[:space:]]*[0-9]+\t/ {
            id=$1
            description=$2
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", description)
            if (description == marker || index(description, marker " [run:") == 1) {
                latest_id=id
                latest_description=description
            }
        }
        END {
            if (latest_id != "") print latest_id "\t" latest_description
            else exit 1
        }
    ' <<< "$output"
}

# Prints the newest root record that has an exact matching Home description.
snapshot_latest_paired_record() {
    local root_config=$1 home_config=$2 marker=$3 root_output home_output

    root_output=$(snapper --csvout --separator $'\t' --no-headers \
        -c "$root_config" list --columns number,description) || return 2
    home_output=$(snapper --csvout --separator $'\t' --no-headers \
        -c "$home_config" list --columns number,description) || return 2
    awk -F '\t' -v marker="$marker" '
        function clean(value) {
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
            return value
        }
        FNR == NR {
            description=clean($2)
            home[description]=1
            next
        }
        {
            description=clean($2)
            if (home[description] &&
                (description == marker || index(description, marker " [run:") == 1)) {
                latest_id=$1
                latest_description=description
            }
        }
        END {
            if (latest_id != "") print latest_id "\t" latest_description
            else exit 1
        }
    ' <(printf '%s\n' "$home_output") <(printf '%s\n' "$root_output")
}

snapshot_config_subvolume_matches() {
    local config=$1 expected=$2 output actual

    output=$(snapper --csvout --separator $'\t' --no-headers -c "$config" \
        get-config --columns key,value) || return 2
    actual=$(awk -F '\t' '
        {
            key=$1
            value=$2
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", key)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
            if (key == "SUBVOLUME") {
                matches++
                subvolume=value
            }
        }
        END {
            if (matches == 1) print subvolume
            else exit 1
        }
    ' <<< "$output") || return 2
    [ "$actual" = "$expected" ]
}

snapshot_config_exists() {
    snapper -c "$1" get-config >/dev/null 2>&1
}

snapshot_description_home_mode() {
    case "$1" in
        *';home:1]') printf 'required\n' ;;
        *';home:0]') printf 'absent\n' ;;
        *) printf 'legacy\n' ;;
    esac
}
