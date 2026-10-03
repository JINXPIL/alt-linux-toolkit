# shellcheck shell=bash
# =============================================================================
# profile.sh — профиль работы системы, выбирается автоматически:
#
#   vm       — запуск в виртуальной машине (VirtualBox, VMware, KVM, Hyper-V…):
#              сон и гашение экрана выключены, chrony шагает часы в любой момент,
#              часы гостя синхронизируются с хостом, проверка часов каждые 2 мин,
#              гостевые дополнения (буфер обмена, общие папки, экран) — lib/guest.sh
#   server   — физическая машина без графики: сон и гашение консоли выключены
#   desktop  — физическая машина с графикой: энергосбережение не трогается
#
# PROFILE=auto в /etc/altctl.conf — определять автоматически (по умолчанию).
# =============================================================================

active_profile() {
    case ${PROFILE,,} in
        vm|server|desktop) echo "${PROFILE,,}"; return 0 ;;
    esac
    if is_vm; then echo vm
    elif [[ -n $(dm_unit) ]]; then echo desktop
    else echo server
    fi
}

profile_title() {
    case $1 in
        vm)      echo "vm (виртуальная машина)" ;;
        server)  echo "server (без графики)" ;;
        desktop) echo "desktop (рабочая станция)" ;;
    esac
}

# profile_has <возможность>
profile_has() {
    local p; p=$(active_profile)
    case $1 in
        nosleep|console)            [[ $p == vm || $p == server ]] ;;
        display)                    [[ $p == vm ]] ;;
        time_vm|host_sync|clock_watch|guest) [[ $p == vm ]] ;;
        *)                          return 1 ;;
    esac
}

profile_apply() {
    local p virt
    p=$(active_profile); virt=$(detect_virt)
    step "Профиль: $(profile_title "$p"), гипервизор: $(virt_title "$virt")"
    if profile_has nosleep; then power_nosleep; fi
    if profile_has console; then console_noblank; fi
    if profile_has display; then display_noblank; fi
    # гостевые дополнения до синхронизации времени: VBoxService тоже подводит часы от хоста
    if profile_has guest; then guest_install no; fi
    if is_yes "$TIME_SYNC"; then time_sync; fi
    state_set profile "$p"
    ok "Профиль $p применён"
}

# Для fix/maintain: доприменить то, что «слетело» (идемпотентно, без лишнего шума)
profile_heal() {
    local p; p=$(active_profile)
    if profile_has nosleep && ! sleep_masked; then
        wrn "Профиль $p: спящие режимы не отключены — отключаю"
        power_nosleep
    fi
    if profile_has console && ! console_noblank_ok; then
        wrn "Профиль $p: гашение консоли включено — отключаю"
        console_noblank
    fi
    if profile_has display && x_installed && ! display_noblank_ok; then
        wrn "Профиль $p: гашение экрана X/XFCE не отключено — отключаю"
        display_noblank
    fi
    if profile_has guest; then guest_heal; fi
    return 0
}

profile_doctor() {
    local p virt
    p=$(active_profile); virt=$(detect_virt)
    step "Профиль и виртуализация"
    if [[ $virt != none ]]; then ok "Гипервизор: $(virt_title "$virt") ($virt)"
    else log "гипервизор: $(virt_title "$virt")"; fi
    log "профиль: $(profile_title "$p")$([[ ${PROFILE,,} == auto ]] && echo ' — выбран автоматически')"
    if [[ $virt != none && $p != vm ]]; then
        wrn "Система в ВМ, но профиль $p — задайте PROFILE=auto или vm"
    fi
    if [[ $virt == oracle ]] && is_yes "$VM_GUEST_TOOLS"; then vbox_doctor; fi
}

cmd_profile() {
    case "${1:-status}" in
        status) profile_doctor; power_doctor; display_doctor ;;
        apply)  profile_apply ;;
        *)      die "altctl profile [status|apply]" ;;
    esac
}
