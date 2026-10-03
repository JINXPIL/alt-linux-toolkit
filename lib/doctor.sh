# shellcheck shell=bash
# shellcheck disable=SC2153  # BRANCH задаётся в load_config
# =============================================================================
# doctor.sh — диагностика без изменений в системе
# =============================================================================

cmd_doctor() {
    local b branch src arch kr dk n root boot failed last
    step "Система"
    log "$(os_field PRETTY_NAME || cat "$ALT_RELEASE" 2>/dev/null || echo 'ALT Linux')"
    if b=$(detect_branch); then
        branch=${b%% *}; src=${b#* }
        ok "Ветка: $branch (определено по: $src)$([[ ${BRANCH,,} != auto ]] && echo ", в конфигурации BRANCH=$BRANCH")"
    else
        bad "Ветку определить не удалось — задайте BRANCH в конфигурации"
    fi
    arch=$(detect_arch)
    log "архитектура: $arch, конфигурация: ${CONFIG_FILE:-встроенные значения}"

    step "Источники пакетов"
    n=$(active_repo_lines | wc -l)
    if (( n == 0 )); then
        bad "Нет активных источников пакетов — altctl repo auto"
    elif repo_needs_fix; then
        wrn "Источники: $REPO_PROBLEM — altctl repo auto"
    else
        ok "Источники: $(repo_branches), $(current_mirror)"
    fi
    if [[ -n ${branch:-} ]]; then
        if key_available "$(branch_key "$branch")"; then ok "Ключ подписи [$(branch_key "$branch")] есть"
        else bad "Нет ключа подписи [$(branch_key "$branch")] в $APT_ETC/vendors.list (пакет alt-gpgkeys)"; fi
        if [[ -n $(current_mirror) ]]; then
            local prc
            if mirror_probe "$(current_mirror)" "$branch" "$arch" >/dev/null; then ok "Зеркало $(current_mirror) отвечает"
            else prc=$?; wrn "Зеркало $(current_mirror): $(probe_reason "$prc") — altctl repo auto выберет другое"; fi
        fi
    fi
    repo_proto_doctor
    apt_net_doctor

    step "Пакеты"
    if [[ -n $(apt_lock_holders) ]]; then wrn "APT сейчас занят: PID $(apt_lock_holders | paste -sd' ')"; fi
    if timeout 60 rpm -q rpm >/dev/null 2>&1; then ok "База RPM читается"; else bad "База RPM не читается — altctl fix"; fi
    if [[ $EUID -eq 0 ]]; then
        if apt-get check >/dev/null 2>&1; then ok "Зависимости пакетов целы"; else wrn "Нарушены зависимости — altctl fix"; fi
    fi
    last=$(state_get last-update || true)
    log "последнее успешное обновление через altctl: ${last:-не выполнялось}"

    step "Ядро"
    kr=$(running_kernel)
    if in_container; then
        log "контейнер — ядро хоста: $kr"
    else
        dk=$(default_kernel)
        log "работает: $kr (тип: $(kernel_flavour || echo '?')), по умолчанию: ${dk:-?}, установлено ядер: $(installed_kernels_count)"
        if reboot_needed; then wrn "Установлено более новое ядро $dk — нужна перезагрузка"
        else ok "Работает ядро по умолчанию"; fi
        if [[ -d $MODULES_DIR/$kr ]]; then ok "Модули для $kr на месте"
        else bad "Нет $MODULES_DIR/$kr — модули работающего ядра удалены"; fi
        have update-kernel || wrn "update-kernel не установлен (поставится при altctl update)"
    fi

    step "Ресурсы и сеть"
    root=$(free_mb /)
    if [[ -n $root ]] && (( root < ROOT_MIN_FREE_MB )); then wrn "Свободно на /: ${root} МБ (< $ROOT_MIN_FREE_MB)"
    else ok "Свободно на /: ${root:-?} МБ"; fi
    if mountpoint -q "$BOOT_DIR" 2>/dev/null; then
        boot=$(free_mb "$BOOT_DIR")
        if (( boot < BOOT_MIN_FREE_MB )); then wrn "Свободно в /boot: ${boot} МБ (< $BOOT_MIN_FREE_MB)"
        else ok "Свободно в /boot: ${boot} МБ"; fi
    fi
    if net_ok; then ok "DNS: $(mirror_host) разрешается"; else bad "DNS не разрешает $(mirror_host)"; fi

    step "Службы"
    local u
    while read -r u; do
        [[ -n $u ]] || continue
        u=${u%.service}
        if ! unit_exists "$u"; then log "служба $u не установлена (altctl services)"; continue; fi
        if systemctl is-active --quiet "$u.service"; then ok "Служба $u работает"
        else wrn "Служба $u не работает — altctl fix"; fi
    done < <(watched_units | sort -u)
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ')
    [[ -n $failed ]] && wrn "Юниты в состоянии failed: $failed"

    profile_doctor
    time_doctor
    power_doctor
    display_doctor
    fw_status
    timer_status
    return 0
}
