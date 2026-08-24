#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/base/targets.sh"

mapfile -t BASE_PACKAGES < <(base_declared_packages)

ARCHLINUXCN_BODY='Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch'

base_target_editor() {
    printf '%s\n' "${BASE_EDITOR:-vim}"
}

base_expect() {
    local phase=$1 label=$2
    shift 2

    if [ "$phase" = check ]; then
        module_check_state "$label" "$@"
    elif ! "$@"; then
        module_verify_failed "$label"
    fi
}

base_required_commands_inspect() {
    local phase=$1 required_command

    while IFS= read -r required_command; do
        [ -n "$required_command" ] || continue
        base_expect "$phase" "command:$required_command" \
            base_required_command_present "$required_command"
    done < <(base_required_commands)
}

base_power_profile_inspect() {
    local phase=$1 provider provider_status=0 unit package_label enabled_label active_label

    provider=$(base_power_profile_provider) || provider_status=$?
    case "$provider_status" in
        0)
            unit=$(base_power_profile_provider_unit "$provider") || {
                if [ "$phase" = check ]; then
                    module_inspection_failed power-profile-provider:unknown
                else
                    module_verify_failed power-profile-provider:unknown
                fi
                return
            }
            if platform_is_fedora; then
                package_label="package:power-profile-provider:$provider"
                enabled_label="service:power-profile-provider:$unit"
                active_label="service:power-profile-provider-active:$unit"
            else
                package_label=package:power-profiles-daemon
                enabled_label=service:power-profiles-daemon
                active_label=service:power-profiles-daemon-active
            fi
            base_expect "$phase" "$package_label" state_package_present "$provider"
            base_expect "$phase" "$enabled_label" \
                state_service_enabled "$unit"
            base_expect "$phase" "$active_label" \
                state_service_active "$unit"
            ;;
        1)
            if [ "$phase" = check ]; then
                module_drift power-profile-provider
            else
                module_verify_failed power-profile-provider
            fi
            ;;
        3)
            if [ "$phase" = check ]; then
                module_inspection_failed power-profile-provider:multiple
            else
                module_verify_failed power-profile-provider:multiple
            fi
            ;;
        *)
            if [ "$phase" = check ]; then
                module_inspection_failed \
                    "power-profile-provider:inspection-error:$provider_status"
            else
                module_verify_failed \
                    "power-profile-provider:inspection-error:$provider_status"
            fi
            ;;
    esac
}

base_inspect() {
    local phase=$1 package unit editor bluetooth_status=0
    local vconsole_font vconsole_status=0
    local gpu_info
    local -a gpu_packages=()

    for package in "${BASE_PACKAGES[@]}"; do
        base_expect "$phase" "package:$package" state_package_present "$package"
    done
    base_required_commands_inspect "$phase"
    base_power_profile_inspect "$phase"
    while IFS= read -r unit; do
        base_expect "$phase" "global-unit:$unit" \
            state_global_service_enabled "$unit"
    done < <(base_global_service_units)
    if platform_is_fedora; then
        base_expect "$phase" fedora:release-file state_file_nonempty /etc/os-release
    else
        base_expect "$phase" pacman:multilib pacman_section_matches \
            /etc/pacman.conf multilib 'Include = /etc/pacman.d/mirrorlist'
        base_expect "$phase" pacman:archlinuxcn pacman_section_matches \
            /etc/pacman.conf archlinuxcn "$ARCHLINUXCN_BODY"
    fi
    editor=$(base_target_editor)
    base_expect "$phase" "command:$editor" command -v "$editor"
    base_expect "$phase" environment:EDITOR key_value_matches \
        /etc/environment EDITOR "$editor"
    vconsole_font=$(base_vconsole_font) || vconsole_status=$?
    case "$vconsole_status" in
        0)
            base_expect "$phase" vconsole:FONT key_value_matches \
                /etc/vconsole.conf FONT "$vconsole_font"
            ;;
        1)
            if [ "$phase" = check ]; then
                module_drift vconsole:font-available
            else
                module_verify_failed vconsole:font-available
            fi
            ;;
        *)
            if [ "$phase" = check ]; then
                module_inspection_failed \
                    "vconsole:font-inspection-error:$vconsole_status"
            else
                module_verify_failed \
                    "vconsole:font-inspection-error:$vconsole_status"
            fi
            ;;
    esac
    if platform_is_fedora; then
        base_expect "$phase" vconsole:font-file \
            base_vconsole_font_file_present
        base_expect "$phase" vconsole:setup \
            base_vconsole_setup_succeeded
    fi
    base_expect "$phase" locale:zh_CN base_locale_present
    base_expect "$phase" flatpak:flathub-system \
        base_flathub_system_remote_present
    base_expect "$phase" sudoers:wheel base_wheel_sudoers_valid

    if ! gpu_info=$(base_gpu_info); then
        if [ "$phase" = check ]; then
            # lspci comes from pciutils, a base package. If it is missing the
            # environment is not converged yet, so treat it as drift and let
            # apply install the tooling before verify re-inspects.
            module_drift gpu:inspection-unavailable
        else
            module_verify_failed gpu:inspection-unavailable
        fi
        return
    fi
    if ! base_nvidia_model_supported "$gpu_info"; then
        if [ "$phase" = check ]; then
            module_inspection_failed gpu:nvidia-unsupported
        else
            module_verify_failed gpu:nvidia-unsupported
        fi
        return
    fi
    if platform_is_fedora && base_gpu_has_vendor NVIDIA "$gpu_info"; then
        local provider_status=0
        base_fedora_nvidia_provider_compatible || provider_status=$?
        case "$provider_status" in
            0) ;;
            1)
                # Provider migration is intentionally not an automatic
                # convergence action.  Mark it as action-required during
                # check so apply cannot run the general Fedora upgrade first.
                if [ "$phase" = check ]; then
                    module_inspection_failed \
                        gpu-provider:nvidia-rpmfusion-exclusive:action-required
                else
                    module_verify_failed \
                        gpu-provider:nvidia-rpmfusion-exclusive
                fi
                ;;
            *)
                if [ "$phase" = check ]; then
                    module_inspection_failed \
                        "gpu-provider:nvidia-rpmfusion-exclusive:inspection-error:$provider_status"
                else
                    module_verify_failed \
                        "gpu-provider:nvidia-rpmfusion-exclusive:inspection-error:$provider_status"
                fi
                ;;
        esac
    fi
    mapfile -t gpu_packages < <(base_gpu_target_packages "$gpu_info")
    for package in "${gpu_packages[@]}"; do
        base_expect "$phase" "gpu-package:$package" \
            base_gpu_package_target_satisfied "$package"
    done
    if [ "$(base_gpu_count "$gpu_info")" -ge 2 ] &&
        base_gpu_has_vendor NVIDIA "$gpu_info"; then
        base_expect "$phase" gpu:GSK_RENDERER key_value_matches \
            /etc/environment GSK_RENDERER gl
    fi
    if [ "$(base_gpu_count "$gpu_info")" -ge 2 ] &&
        base_gpu_has_vendor NVIDIA "$gpu_info" &&
        systemctl list-unit-files switcheroo-control.service >/dev/null 2>&1; then
        base_expect "$phase" service:switcheroo-control \
            state_service_enabled switcheroo-control.service
    fi
    base_bluetooth_present || bluetooth_status=$?
    case "$bluetooth_status" in
        0)
            base_expect "$phase" package:bluez state_package_present bluez
            base_expect "$phase" service:bluetooth \
                state_service_enabled bluetooth.service
            base_expect "$phase" service:bluetooth-active \
                state_service_active bluetooth.service
            ;;
        1) ;;
        *)
            if [ "$phase" = check ]; then
                # Detection tools (usbutils/pciutils) are base packages that may
                # not be installed yet; that is drift, not an inspection error.
                module_drift bluetooth:inspection-unavailable
            else
                module_verify_failed bluetooth:inspection-unavailable
            fi
            ;;
    esac

    if [ -z "${TARGET_USER:-}" ]; then
        if [ "$phase" = check ]; then
            module_drift target-user
        else
            module_verify_failed target-user
        fi
    else
        base_expect "$phase" "user:$TARGET_USER" state_user_exists "$TARGET_USER"
        if state_user_exists "$TARGET_USER"; then
            base_expect "$phase" "group:$TARGET_USER:wheel" \
                state_user_in_group "$TARGET_USER" wheel
            if [ -n "${HOME_DIR:-}" ]; then
                base_expect "$phase" user:xdg-dirs \
                    state_file_nonempty "$HOME_DIR/.config/user-dirs.dirs"
            else
                [ "$phase" = check ] && module_inspection_failed target-home ||
                    module_verify_failed target-home
            fi
        fi
    fi
}

base_check() { base_inspect check; }

base_apply() {
    local implementation="$SHORIN_ROOT/scripts/modules/base"
    bash "$implementation/system-apply.sh" || return
    bash "$implementation/essentials-apply.sh" || return
    bash "$implementation/user-apply.sh" || return
    bash "$implementation/gpu-apply.sh" || return
}

base_verify() { base_inspect verify; }

module_main base "$@"
