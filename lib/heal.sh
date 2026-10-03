# shellcheck shell=bash
# =============================================================================
# heal.sh — самовосстановление типичных поломок ALT Linux
#   блокировки APT, повреждённая база RPM, нарушенные зависимости,
#   несинхронизированное время, нехватка места, сеть/DNS, модули ядра, службы
# =============================================================================

apt_lock_files() { echo "$APT_STATE/lists/lock" "$APT_CACHE/archives/lock"; }

apt_lock_holders() {
    local -a locks
    read -ra locks <<<"$(apt_lock_files)"
    if have fuser; then
        fuser "${locks[@]}" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true
    else
        pgrep -x 'apt-get|rpm|synaptic|synaptic-pkexec|packagekitd' || true
    fi
}

heal_apt_locks() {
    [[ ${LOCKS_OK:-0} == 1 ]] && return 0      # уже проверено в этом запуске
    local waited=0 holders f removed=0
    holders=$(apt_lock_holders)
    while [[ -n $holders ]]; do
        if (( waited >= LOCK_WAIT )); then
            bad "APT занят дольше ${LOCK_WAIT} с процессами: $(paste -sd' ' <<<"$holders") — дождитесь их или закройте Synaptic/Центр приложений"
            return 1
        fi
        (( waited == 0 )) && log "APT занят (PID $(paste -sd' ' <<<"$holders")), жду до ${LOCK_WAIT} с..."
        sleep 5; waited=$((waited + 5))
        holders=$(apt_lock_holders)
    done
    # живых владельцев нет — оставшиеся lock-файлы «мёртвые»
    for f in $(apt_lock_files); do
        [[ -e $f ]] && { run rm -f "$f"; removed=$((removed + 1)); }
    done
    if ! pgrep -x 'rpm|apt-get' >/dev/null && compgen -G "$RPM_DB/__db.*" >/dev/null; then
        run rm -f "$RPM_DB"/__db.*
        removed=$((removed + 1))
    fi
    LOCKS_OK=1
    ok "Блокировки APT/RPM: свободно (снято устаревших: $removed)"
}

heal_rpmdb() {
    if timeout 120 rpm -q rpm >/dev/null 2>&1; then
        ok "База RPM читается"
        return 0
    fi
    wrn "База RPM не читается — перестраиваю"
    run rm -f "$RPM_DB"/__db.*
    if run rpm --rebuilddb && timeout 120 rpm -q rpm >/dev/null 2>&1; then
        ok "База RPM перестроена"
    else
        bad "База RPM повреждена и не восстановилась (rpm --rebuilddb)"
        return 1
    fi
}

heal_deps() {
    if apt-get check >/dev/null 2>&1; then
        ok "Зависимости пакетов целы"
        return 0
    fi
    wrn "Нарушены зависимости — apt-get -f install"
    if run apt-get -f install -y; then ok "Зависимости исправлены"
    else bad "apt-get -f install не исправил зависимости"; return 1; fi
}

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }

heal_disk() {
    local root boot
    root=$(free_mb /)
    if [[ -n $root ]] && (( root < ROOT_MIN_FREE_MB )); then
        wrn "Мало места на /: ${root} МБ — очищаю кэш пакетов"
        run apt-get clean
    elif [[ -n $root ]]; then
        ok "Свободно на /: ${root} МБ"
    fi
    if mountpoint -q "$BOOT_DIR" 2>/dev/null; then
        boot=$(free_mb "$BOOT_DIR")
        if [[ -n $boot ]] && (( boot < BOOT_MIN_FREE_MB )); then
            if ! reboot_needed && have remove-old-kernels && (( $(installed_kernels_count) > 1 )); then
                wrn "Мало места в /boot: ${boot} МБ — удаляю старые ядра"
                run remove-old-kernels -y
            else
                wrn "Мало места в /boot: ${boot} МБ — перезагрузитесь в новое ядро и запустите altctl fix"
            fi
        else
            ok "Свободно в /boot: ${boot} МБ"
        fi
    fi
}

mirror_host() {
    local m first=""
    for first in $MIRRORS; do break; done
    m=$(current_mirror); m=${m:-$first}; m=${m#*://}
    echo "${m%%/*}"
}

net_ok() {
    local h; h=$(mirror_host)
    [[ -z $h ]] && return 0
    getent hosts "$h" >/dev/null 2>&1
}

heal_network() {
    local h; h=$(mirror_host)
    if ! ip route show default 2>/dev/null | grep -q .; then
        bad "Нет маршрута по умолчанию — сеть не настроена"
        return 1
    fi
    if net_ok; then ok "Сеть и DNS: $h разрешается"
    else bad "DNS не разрешает $h — проверьте /etc/resolv.conf и подключение"; return 1; fi
}

heal_modules() {
    in_container && return 0
    local kr; kr=$(running_kernel)
    if [[ ! -d $MODULES_DIR/$kr ]]; then
        bad "Нет каталога модулей $MODULES_DIR/$kr — работающее ядро удалено; перезагрузитесь"
        return 1
    fi
    if [[ ! -s $MODULES_DIR/$kr/modules.dep ]]; then
        wrn "Нет modules.dep для $kr — пересобираю"
        run depmod -a "$kr"
    fi
    if systemctl is-failed --quiet systemd-modules-load.service 2>/dev/null; then
        wrn "Часть модулей из /etc/modules-load.d не загрузилась: journalctl -b -u systemd-modules-load"
    else
        ok "Модули ядра $kr на месте"
    fi
}

# Службы, которые должны работать: WATCH_UNITS + явно указанные в SERVICES
watched_units() {
    local s u
    for u in $WATCH_UNITS; do echo "$u"; done
    for s in $SERVICES; do
        [[ $s == *:* ]] || continue
        tr ',' '\n' <<<"${s#*:}"
    done
}

heal_units() {
    local u failed
    while read -r u; do
        [[ -n $u ]] || continue
        u=${u%.service}
        unit_exists "$u" || continue
        if systemctl is-active --quiet "$u.service"; then
            ok "Служба $u работает"
        else
            wrn "Служба $u не работает — перезапуск"
            run systemctl enable "$u.service" >/dev/null 2>&1 || true
            if run systemctl restart "$u.service" && { [[ $DRY_RUN == 1 ]] || systemctl is-active --quiet "$u.service"; }; then
                ok "Служба $u поднята"
            else
                bad "Служба $u не запускается: journalctl -u $u -n 50"
            fi
        fi
    done < <(watched_units | sort -u)

    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ')
    [[ -n $failed ]] && wrn "Юниты в состоянии failed: $failed (systemctl status <юнит>)"
    return 0
}

heal_all() {
    step "Самовосстановление"
    heal_apt_locks
    heal_rpmdb
    heal_disk
    heal_network
    time_heal
    apt_net_heal
    if repo_needs_fix; then
        wrn "Источники пакетов: $REPO_PROBLEM — перенастраиваю"
        repo_auto
    fi
    repo_https_heal
    heal_deps
    heal_modules
    heal_units
    profile_heal
    fw_check
}
