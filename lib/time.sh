# shellcheck shell=bash
# =============================================================================
# time.sh — системное время и аппаратные часы (RTC).
#
# В ALT службой времени является chrony (chronyd.service); systemd-timesyncd в
# базовой поставке нет. Типичная поломка в ВМ: хост ставится на паузу или
# засыпает, гость «просыпается» с отставшими часами, а chrony по умолчанию
# шагает время только при старте (makestep 1 3) — дальше подводит часы
# медленно, часами. Отсюда ошибки TLS/подписей и «зависшие» таймеры.
#
# Что делает altctl:
#   * ставит/включает chrony, гасит конкурирующие демоны (timesyncd, ntpd);
#   * в профиле vm добавляет в chrony.conf блок: makestep 1 -1 (шаг в любой
#     момент), rtcsync и, если гипервизор даёт PTP-часы (KVM, Hyper-V),
#     refclock PHC — часы гостя идут прямо от часов хоста;
#   * гостевые инструменты гипервизора ставит lib/guest.sh (altctl guest install);
#   * синхронизирует сразу: burst -> makestep -> hwclock --systohc;
#   * если UDP 123 закрыт — грубо ставит время по заголовку Date зеркала;
#   * в профиле vm каждые CLOCK_WATCH_INTERVAL проверяет смещение (altctl time check).
# =============================================================================

CHRONY_BEGIN="# >>> altctl: блок управляется altctl (altctl time sync), не правьте вручную"
CHRONY_END="# <<< altctl"
CLOCK_UNIT="altctl-clock"

chronyd_bin() { command -v chronyd 2>/dev/null || { [[ -x /usr/sbin/chronyd ]] && echo /usr/sbin/chronyd; }; }
chrony_installed() { [[ -n $(chronyd_bin) ]] && have chronyc; }
chrony_active() { systemctl is-active --quiet chronyd.service 2>/dev/null; }

abs_int() { awk -v x="$1" 'BEGIN { if (x < 0) x = -x; printf "%d", x + 0.5 }'; }

# Смещение системных часов по chrony (секунды, по модулю, с дробной частью)
chrony_offset() {
    chronyc -n -c tracking 2>/dev/null | awk -F, 'NR == 1 { x = $5; if (x < 0) x = -x; printf "%.3f", x }'
}
chrony_leap() { chronyc -n -c tracking 2>/dev/null | awk -F, 'NR == 1 { print $14 }'; }
chrony_ref()  { chronyc -n -c tracking 2>/dev/null | awk -F, 'NR == 1 { print $2 }'; }
chrony_synced() {
    local l; l=$(chrony_leap)
    [[ -n $l && $l != "Not synchronised" ]]
}
# Сколько источников отвечали хотя бы раз (поле reach != 0)
chrony_reachable() { chronyc -n -c sources 2>/dev/null | awk -F, '$6 != "0" && $6 != "" { n++ } END { print n + 0 }'; }

kernel_synced() {
    local s
    s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null \
        || timedatectl status 2>/dev/null | sed -n 's/.*[Ss]ynchronized: //p')
    [[ $s == yes ]]
}

# --- Время по HTTP (запасной путь, когда NTP недоступен) ----------------------
http_epoch() {
    local m d
    for m in $MIRRORS; do
        # именно http://: при сбитых часах сертификат HTTPS покажется недействительным
        m="http://$(url_host_path "$m")"
        if have curl; then
            d=$(curl -fsSI --max-time "$MIRROR_TIMEOUT" "${m%/}/" 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -n1)
        elif have wget; then
            d=$(wget -qS --spider -T "$MIRROR_TIMEOUT" -t 1 "${m%/}/" 2>&1 | sed -n 's/^ *[Dd]ate: //p' | head -n1)
        fi
        [[ -n $d ]] && date -u -d "$d" +%s 2>/dev/null && return 0
    done
    return 1
}

http_offset() { local h; h=$(http_epoch) || return 1; echo $(( $(date -u +%s) - h )); }

time_http_step() {
    is_yes "$TIME_HTTP_FALLBACK" || return 1
    local h now off
    h=$(http_epoch) || { wrn "Не удалось узнать время ни по NTP, ни по HTTP (нет сети?)"; return 1; }
    now=$(date -u +%s); off=$(( now - h )); off=${off#-}
    if (( off <= TIME_MAX_OFFSET + 1 )); then
        ok "Время сверено по HTTP (Date зеркала): расхождение ${off} с"
        return 0
    fi
    if run date -u -s "@$h" >/dev/null; then
        wrn "NTP недоступен — время выставлено по HTTP-заголовку Date (было расхождение ${off} с, точность ~1 с)"
    else
        bad "Не удалось выставить время (date -s)"; return 1
    fi
}

# --- Установка и конфигурация chrony ------------------------------------------
ensure_chrony() {
    chrony_installed && return 0
    log "chrony не установлен — ставлю"
    # если часы сбиты сильно, apt может отвергнуть подписи — сначала грубая коррекция
    local off
    if off=$(http_offset 2>/dev/null) && (( ${off#-} > 300 )); then
        time_http_step || true
    fi
    prepare_install || return 1
    pkg_install_any chrony >/dev/null || return 1
    [[ $DRY_RUN == 1 ]] || chrony_installed
}

# Конкурирующие службы времени: два демона, подводящие одни часы, дают скачки
time_conflicts_off() {
    local u
    for u in systemd-timesyncd ntpd openntpd ntpdate; do
        unit_exists "$u" || continue
        if systemctl is-enabled --quiet "$u.service" 2>/dev/null || systemctl is-active --quiet "$u.service" 2>/dev/null; then
            run systemctl disable --now "$u.service" >/dev/null 2>&1 || true
            log "отключена конкурирующая служба времени $u"
        fi
    done
}

# PTP-часы гипервизора (/dev/ptpN с именем KVM / hyperv / VMware)
host_ptp_device() {
    local d name
    # KVM отдаёт часы хоста через модуль ptp_kvm — загрузить и закрепить в автозагрузке
    if [[ $(detect_virt) == kvm ]] && modinfo ptp_kvm >/dev/null 2>&1; then
        compgen -G "$SYS_PTP/ptp*" >/dev/null || run modprobe ptp_kvm >/dev/null 2>&1 || true
        if [[ ! -e $MODULES_LOAD_DIR/altctl-ptp.conf ]]; then
            printf 'ptp_kvm\n' | write_file "$MODULES_LOAD_DIR/altctl-ptp.conf" 0644 || true
        fi
    fi
    for d in "$SYS_PTP"/ptp*; do
        [[ -r $d/clock_name ]] || continue
        name=$(<"$d/clock_name")
        case $name in
            *KVM*|*kvm*|*hyperv*|*Hyper-V*|*VMware*)
                echo "$DEV_DIR/${d##*/}"; return 0 ;;
        esac
    done
    return 1
}

chrony_block_render() {
    local ptp=$1 s
    echo "$CHRONY_BEGIN"
    echo "# Профиль vm: шагать часы при расхождении > 1 с в любой момент (паузы/сон хоста)"
    echo "makestep 1 -1"
    grep -qE '^[[:space:]]*rtcfile' "$CHRONY_CONF" 2>/dev/null || echo "rtcsync"
    if [[ -n $ptp ]]; then
        echo "# Часы хоста через PTP-устройство гипервизора"
        echo "refclock PHC $ptp poll 2 dpoll -2 offset 0 prefer"
    fi
    for s in $NTP_SERVERS; do echo "server $s iburst maxpoll 6"; done
    echo "$CHRONY_END"
}

chrony_strip_block() { awk -v b="$CHRONY_BEGIN" -v e="$CHRONY_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$CHRONY_CONF"; }

# chrony_configure <vm:yes|no> -> 0 — без изменений, 10 — файл изменён
chrony_configure() {
    local vm=$1 ptp="" new s
    [[ -r $CHRONY_CONF ]] || { wrn "Нет $CHRONY_CONF — оставляю настройки chrony по умолчанию"; return 0; }
    new=$(mk_tmp)
    chrony_strip_block > "$new"
    if [[ $vm == yes ]]; then
        ptp=$(host_ptp_device || true)
        [[ -n $(tail -c1 "$new") ]] && echo >> "$new"
        chrony_block_render "$ptp" >> "$new"
    elif [[ -n $NTP_SERVERS ]]; then
        { echo "$CHRONY_BEGIN"; for s in $NTP_SERVERS; do echo "server $s iburst"; done; echo "$CHRONY_END"; } >> "$new"
    fi
    if cmp -s "$new" "$CHRONY_CONF"; then return 0; fi
    backup_file chrony "$CHRONY_CONF"
    write_file "$CHRONY_CONF" 0644 < "$new" || return 1
    if [[ $vm == yes ]]; then
        log "chrony.conf: makestep 1 -1, rtcsync${ptp:+, PTP-часы хоста $ptp}"
    fi
    return 10
}

# Запуск chronyd с откатом конфигурации, если он не поднялся
chrony_restart_safe() {
    run systemctl enable chronyd.service >/dev/null 2>&1 || true
    if run systemctl restart chronyd.service && { [[ $DRY_RUN == 1 ]] || { sleep 1; chrony_active; }; }; then
        return 0
    fi
    local last
    last=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'chrony-*' 2>/dev/null | sort | tail -n1)
    if [[ -n $last && -r $last$CHRONY_CONF ]]; then
        wrn "chronyd не запустился с новой конфигурацией — возвращаю прежнюю"
        run cp -a "$last$CHRONY_CONF" "$CHRONY_CONF"
        run systemctl restart chronyd.service
    fi
    chrony_active
}

# --- Аппаратные часы ----------------------------------------------------------
rtc_present() { compgen -G "$DEV_DIR/rtc*" >/dev/null; }

rtc_write() {
    if ! have hwclock || ! rtc_present; then
        log "RTC недоступен — запись в аппаратные часы пропущена"; return 0
    fi
    if run hwclock --systohc; then ok "Аппаратные часы (RTC) записаны текущим временем"
    else wrn "hwclock --systohc завершился с ошибкой"; fi
}

# Расхождение RTC и системного времени, секунды (только root)
rtc_drift() {
    if ! have hwclock || ! rtc_present || [[ $EUID -ne 0 ]]; then return 1; fi
    local r
    r=$(hwclock --get 2>/dev/null || hwclock -r 2>/dev/null) || return 1
    r=$(date -d "$r" +%s 2>/dev/null) || return 1   # hwclock печатает местное время со смещением
    echo $(( $(date -u +%s) - r ))
}

# --- Синхронизация ------------------------------------------------------------
chrony_wait_reach() {
    local waited=0
    [[ $DRY_RUN == 1 ]] && return 0
    while (( waited < TIME_SYNC_WAIT )); do
        (( $(chrony_reachable) > 0 )) && return 0
        sleep 2; waited=$((waited + 2))
    done
    return 1
}

time_step_now() {
    run chronyc burst 4/4 >/dev/null 2>&1 || true
    if chrony_wait_reach; then
        [[ $DRY_RUN == 1 ]] || sleep 3
        run chronyc makestep >/dev/null
        return 0
    fi
    return 1
}

time_sync() {
    step "Синхронизация времени"
    if in_container; then log "Контейнер — временем управляет хост"; return 0; fi
    local vm=no rc=0 off
    profile_has time_vm && vm=yes

    ensure_chrony || { bad "chrony не установлен"; time_http_step; return 1; }
    time_conflicts_off

    chrony_configure "$vm" || rc=$?
    if (( rc == 10 )) || ! chrony_active; then
        chrony_restart_safe || { bad "chronyd не запускается: journalctl -u chronyd -n 50"; time_http_step; return 1; }
    fi

    if [[ $DRY_RUN == 1 ]]; then
        time_step_now
        ok "Время будет синхронизировано chrony (dry-run)"
    elif time_step_now; then
        off=$(chrony_offset)
        ok "Время синхронизировано chrony (источник: $(chrony_ref || echo '?'), смещение ${off:-?} с)"
    else
        wrn "Ни один NTP-сервер не ответил за ${TIME_SYNC_WAIT} с (закрыт UDP 123?)"
        time_http_step || true
    fi
    rtc_write
    [[ $vm == yes ]] && clock_watch_on
    return 0
}

# Лёгкая проверка для таймера: корректирует, только если часы ушли
time_check() {
    in_container && return 0
    chrony_installed || return 0
    chrony_active || run systemctl start chronyd.service >/dev/null 2>&1 || true
    local off
    off=$(chrony_offset); off=$(abs_int "${off:-0}")
    if (( off > TIME_MAX_OFFSET )) || ! chrony_synced; then
        if time_step_now; then
            ok "Часы скорректированы (было смещение ~${off} с)"
            rtc_write
        else
            time_http_step || true
        fi
    fi
    return 0
}

# Самовосстановление для fix/maintain: полная синхронизация только при проблеме
time_heal() {
    is_yes "$TIME_SYNC" || return 0
    in_container && return 0
    if ! chrony_installed; then wrn "chrony не установлен"; time_sync; return; fi
    local need="" off
    chrony_active || need="chronyd не запущен"
    if [[ -z $need ]]; then
        off=$(abs_int "$(chrony_offset || echo 0)")
        if ! chrony_synced; then need="часы не синхронизированы"
        elif (( off > TIME_MAX_OFFSET )); then need="смещение ${off} с"; fi
    fi
    if [[ -z $need ]] && profile_has time_vm && ! grep -qF "$CHRONY_BEGIN" "$CHRONY_CONF" 2>/dev/null; then
        need="нет настроек chrony для ВМ"
    fi
    if [[ -n $need ]]; then
        wrn "Время: $need — синхронизирую"
        time_sync
    else
        ok "Время синхронизировано (chrony, смещение ${off} с)"
        profile_has clock_watch && ! clock_watch_enabled && clock_watch_on
    fi
    return 0
}

# --- Таймер проверки часов (профиль vm) ---------------------------------------
clock_watch_enabled() { systemctl is-enabled --quiet "$CLOCK_UNIT.timer" 2>/dev/null; }

clock_watch_on() {
    local exe; exe=$(readlink -f "$ALTCTL_HOME/altctl")
    write_file "$SYSTEMD_DIR/$CLOCK_UNIT.service" 0644 <<EOF
[Unit]
Description=altctl: проверка и коррекция системных часов
After=chronyd.service

[Service]
Type=oneshot
ExecStart=$exe --yes time check
# в журнал попадают только коррекции, а не каждый запуск раз в пару минут
SyslogLevel=notice
LogLevelMax=notice
EOF
    write_file "$SYSTEMD_DIR/$CLOCK_UNIT.timer" 0644 <<EOF
[Unit]
Description=altctl: проверка часов каждые $CLOCK_WATCH_INTERVAL (паузы и сон хоста)

[Timer]
OnBootSec=1min
OnUnitActiveSec=$CLOCK_WATCH_INTERVAL
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
    run systemctl daemon-reload
    if run systemctl enable --now "$CLOCK_UNIT.timer" >/dev/null 2>&1; then
        ok "Проверка часов каждые $CLOCK_WATCH_INTERVAL включена ($CLOCK_UNIT.timer)"
    else
        wrn "Не удалось включить $CLOCK_UNIT.timer"
    fi
}

clock_watch_off() {
    run systemctl disable --now "$CLOCK_UNIT.timer" >/dev/null 2>&1 || true
    ok "Проверка часов выключена"
}

# --- Диагностика --------------------------------------------------------------
time_doctor() {
    step "Время"
    if in_container; then log "контейнер — временем управляет хост"; return 0; fi
    local off h d
    if ! chrony_installed; then
        wrn "chrony не установлен — altctl time sync"
        if off=$(http_offset 2>/dev/null); then log "расхождение с HTTP-временем зеркала: ${off} с"; fi
    elif ! chrony_active; then
        wrn "chronyd не запущен — altctl time sync"
    else
        off=$(chrony_offset)
        log "chrony: источник $(chrony_ref || echo '?'), отвечающих источников: $(chrony_reachable), состояние: $(chrony_leap || echo '?')"
        if ! chrony_synced; then wrn "chrony ещё не синхронизировал часы — altctl time sync"
        elif (( $(abs_int "${off:-0}") > TIME_MAX_OFFSET )); then wrn "Смещение часов ${off} с — altctl time sync"
        else ok "chronyd работает, смещение ${off} с"; fi
    fi
    if have timedatectl; then
        if kernel_synced; then ok "System clock synchronized: yes"
        else wrn "System clock synchronized: no"; fi
    fi
    for h in systemd-timesyncd ntpd; do
        unit_exists "$h" && systemctl is-active --quiet "$h.service" 2>/dev/null \
            && wrn "Одновременно работает $h — конфликт с chrony (altctl time sync отключит)"
    done
    if d=$(rtc_drift); then
        if (( ${d#-} > 60 )); then wrn "RTC расходится с системным временем на ${d} с — altctl time sync"
        else ok "RTC совпадает с системным временем (±${d#-} с)"; fi
    fi
    if profile_has clock_watch; then
        if clock_watch_enabled; then ok "Проверка часов ($CLOCK_UNIT.timer) включена"
        else wrn "Профиль vm: проверка часов выключена — altctl time sync"; fi
    fi
    return 0
}

cmd_time() {
    case "${1:-status}" in
        status) time_doctor ;;
        sync)   time_sync ;;
        check)  time_check ;;
        watch)
            case "${2:-on}" in
                on)  clock_watch_on ;;
                off) clock_watch_off ;;
                *)   die "altctl time watch [on|off]" ;;
            esac ;;
        *) die "altctl time [status|sync|check|watch on|off]" ;;
    esac
}
