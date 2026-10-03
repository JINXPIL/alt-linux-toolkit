# shellcheck shell=bash
# =============================================================================
# update.sh — обновление системы целиком:
#   apt-get update (с переключением зеркала при сбое) -> dist-upgrade ->
#   update-kernel (новое ядро + модули к нему) -> remove-old-kernels ->
#   flatpak -> очистка кэша -> перезагрузка при необходимости
#
# В ALT apt-get dist-upgrade НЕ ставит новое ядро: пакеты ядра имеют версию
# в имени (kernel-image-6.12-...). Новое ядро и согласованные с ним модули
# (kernel-modules-*-<flavour>) ставит только update-kernel.
# =============================================================================

apt_update_resilient() {
    if run apt-get update; then ok "Индексы пакетов обновлены"; return 0; fi

    wrn "apt-get update завершился с ошибкой — очищаю списки и повторяю"
    run find "$APT_STATE/lists" -maxdepth 1 -type f ! -name lock -delete
    if run apt-get update; then ok "Индексы пакетов обновлены со второй попытки"; return 0; fi

    if ! net_ok; then
        bad "Нет сети/DNS — обновление пропущено"
        return 1
    fi
    wrn "Зеркало $(current_mirror) отвечает с ошибками — выбираю другое"
    if repo_auto "$(current_mirror)" && run apt-get update; then
        ok "Индексы пакетов обновлены после смены зеркала"
        return 0
    fi
    bad "Не удалось обновить индексы пакетов"
    return 1
}

lists_fresh() {
    find "$APT_STATE/lists" -maxdepth 1 -type f -name '*release*' -mmin -360 2>/dev/null | grep -q .
}

system_upgrade() {
    if run apt-get dist-upgrade -y; then ok "Пакеты обновлены (dist-upgrade)"; return 0; fi
    wrn "dist-upgrade с ошибкой — чиню зависимости и повторяю"
    run apt-get -f install -y || true
    if run apt-get dist-upgrade -y; then ok "Пакеты обновлены со второй попытки"
    else bad "dist-upgrade не выполнен — подробности в выводе выше"; return 1; fi
}

ensure_update_kernel() {
    have update-kernel && return 0
    log "Утилита update-kernel не установлена — ставлю"
    run apt-get install -y update-kernel && { [[ $DRY_RUN == 1 ]] || have update-kernel; }
}

kernel_update() {
    is_yes "$UPDATE_KERNEL" || { log "Обновление ядра отключено (UPDATE_KERNEL=no)"; return 0; }
    in_container && { log "Контейнер — ядро управляется хостом, пропускаю"; return 0; }
    ensure_update_kernel || { bad "Нет update-kernel — ядро не обновлено"; return 1; }

    local before after
    before=$(default_kernel)
    guest_kernel_prepare
    if run update-kernel -y; then
        after=$(default_kernel)
        if [[ $after != "$before" ]]; then ok "Установлено ядро $after вместе с модулями"
        else ok "Ядро и модули к нему актуальны (по умолчанию: ${after:-?})"; fi
    else
        wrn "update-kernel завершился с кодом ошибки (часто — просто нечего обновлять)"
    fi
    # ядро, которое загрузится следующим, должно иметь модули гостевых дополнений
    guest_kernel_verify "$(default_kernel)"
}

kernel_cleanup() {
    is_yes "$REMOVE_OLD_KERNELS" || return 0
    in_container && return 0
    have remove-old-kernels || return 0
    if reboot_needed; then
        log "Старые ядра удалю после загрузки в новое"
        return 0
    fi
    (( $(installed_kernels_count) > 1 )) || return 0
    if run remove-old-kernels -y; then ok "Старые ядра удалены, оставлено рабочее $(running_kernel)"
    else wrn "remove-old-kernels завершился с ошибкой"; fi
}

flatpak_update() {
    is_yes "$UPDATE_FLATPAK" && have flatpak || return 0
    if run flatpak update -y --noninteractive; then ok "Flatpak-приложения обновлены"
    else wrn "flatpak update завершился с ошибкой"; fi
}

cache_clean() {
    is_yes "$CLEAN_CACHE" || return 0
    run apt-get clean && ok "Кэш пакетов очищен"
}

reboot_handle() {
    if ! reboot_needed; then
        [[ $DRY_RUN == 1 ]] || rm -f "$STATE_DIR/reboot-required"
        return 0
    fi
    state_set reboot-required "$(default_kernel)"
    if is_yes "$AUTO_REBOOT" && (( GUEST_KERNEL_BROKEN )); then
        bad "Автоперезагрузка отменена: в новом ядре $(default_kernel) нет модулей VirtualBox (altctl guest fix)"
    elif is_yes "$AUTO_REBOOT"; then
        wrn "Новое ядро $(default_kernel): перезагрузка через $REBOOT_DELAY_MIN мин (AUTO_REBOOT=yes)"
        run shutdown -r "+$REBOOT_DELAY_MIN" "altctl: установлено новое ядро $(default_kernel)"
    else
        wrn "Нужна перезагрузка: работает $(running_kernel), установлено $(default_kernel)"
    fi
}

cmd_update() {
    step "Обновление системы"
    heal_apt_locks || return 1
    if repo_needs_fix; then
        wrn "Источники пакетов: $REPO_PROBLEM — перенастраиваю"
        repo_auto || return 1
    fi
    if is_yes "$APT_NET_TUNING" && ! apt_net_ok; then apt_net_apply; fi
    apt_update_resilient || return 1
    system_upgrade
    kernel_update
    kernel_cleanup
    flatpak_update
    cache_clean
    reboot_handle
    (( FAILS == 0 )) && state_set last-update "$(date '+%F %T')"
    return 0
}

cmd_kernel() {
    step "Ядро и модули"
    heal_apt_locks || return 1
    lists_fresh || apt_update_resilient || return 1
    kernel_update
    kernel_cleanup
    reboot_handle
}
