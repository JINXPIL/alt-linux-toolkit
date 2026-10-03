# shellcheck shell=bash
# =============================================================================
# display.sh — графика: гашение экрана X/XFCE и восстановление display manager.
#
# Чёрный экран в ВМ обычно вызывает DPMS: X-сервер по умолчанию гасит экран
# через 10 мин, xfce4-power-manager — по своим настройкам, а виртуальная
# видеокарта после «выключения монитора» не просыпается. altctl:
#   * пишет /etc/X11/xorg.conf.d/90-altctl-noblank.conf (BlankTime/DPMS = 0) —
#     действует на любой X-сервер, включая экран входа LightDM;
#   * в открытых сеансах XFCE ставит blank-on-ac, dpms-on-ac-sleep,
#     dpms-on-ac-off = 0 через xfconf-query от имени владельца сеанса
#     и сразу выключает DPMS (xset -dpms);
#   * altctl display wake    — «разбудить» экран без потери сеанса;
#   * altctl display restart — перезапуск display manager после проверок.
# =============================================================================

XORG_NOBLANK="90-altctl-noblank.conf"
SESSION_PROCS='xfce4-session|mate-session|gnome-session-binary|cinnamon-session|lxqt-session|lxsession|plasmashell|startplasma-x11'

x_installed() { [[ -d ${X11_CONF_DIR%/*} ]] || have Xorg; }

# Юнит активного display manager: lightdm.service, sddm.service, gdm.service …
dm_unit() {
    local u
    u=$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)
    if [[ $u == *.service && $u != display-manager.service ]] && unit_exists "${u%.service}"; then
        echo "$u"; return 0
    fi
    for u in lightdm sddm gdm lxdm slim xdm; do
        if unit_exists "$u" && systemctl is-enabled --quiet "$u.service" 2>/dev/null; then
            echo "$u.service"; return 0
        fi
    done
}

# Графические сеансы: «PID пользователь» процессов-лидеров сеанса
graphical_sessions() {
    local pid user
    for pid in $(pgrep -x "$SESSION_PROCS" 2>/dev/null); do
        user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -n $user ]] && echo "$pid $user"
    done
}

proc_env() { tr '\0' '\n' < "$PROC_DIR/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -n1; }

# Запуск команды в окружении графического сеанса от имени его владельца
as_session() {
    local pid=$1 user disp xauth bus; shift
    user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    disp=$(proc_env "$pid" DISPLAY); xauth=$(proc_env "$pid" XAUTHORITY)
    bus=$(proc_env "$pid" DBUS_SESSION_BUS_ADDRESS)
    [[ -n $user && -n $disp ]] || return 1
    local -a envv=(env "DISPLAY=$disp")
    [[ -n $xauth ]] && envv+=("XAUTHORITY=$xauth")
    [[ -n $bus ]] && envv+=("DBUS_SESSION_BUS_ADDRESS=$bus")
    if have runuser; then run runuser -u "$user" -- "${envv[@]}" "$@"
    elif have sudo;  then run sudo -n -u "$user" -- "${envv[@]}" "$@"
    else return 1; fi
}

xorg_noblank_render() {
    cat <<'EOF'
# Создано altctl: экран не гаснет и монитор не «выключается» (профиль vm).
# Удалить: rm этого файла и перезапустить графику (altctl display restart).
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOF
}

display_noblank_ok() {
    [[ -r $X11_CONF_DIR/$XORG_NOBLANK ]] && cmp -s <(xorg_noblank_render) "$X11_CONF_DIR/$XORG_NOBLANK"
}

xfce_noblank() {
    local pid=$1 prop
    have xfconf-query || return 0
    for prop in blank-on-ac dpms-on-ac-sleep dpms-on-ac-off blank-on-battery dpms-on-battery-sleep dpms-on-battery-off; do
        as_session "$pid" xfconf-query -c xfce4-power-manager -p "/xfce4-power-manager/$prop" -n -t int -s 0 >/dev/null 2>&1 || true
    done
    as_session "$pid" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false >/dev/null 2>&1 || true
    # хранитель экрана XFCE, если установлен
    if [[ $DRY_RUN != 1 ]] && as_session "$pid" xfconf-query -c xfce4-screensaver -p /saver/enabled >/dev/null 2>&1; then
        as_session "$pid" xfconf-query -c xfce4-screensaver -p /saver/enabled -s false >/dev/null 2>&1 || true
    fi
}

display_noblank() {
    if ! x_installed; then log "X-сервер не установлен — гашение экрана настраивать не нужно"; return 0; fi
    if ! display_noblank_ok; then
        xorg_noblank_render | write_file "$X11_CONF_DIR/$XORG_NOBLANK" 0644 \
            || { bad "Не удалось записать $X11_CONF_DIR/$XORG_NOBLANK"; return 1; }
    fi
    local pid user n=0 proc
    while read -r pid user; do
        [[ -n $pid ]] || continue
        proc=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ $proc == xfce4-session ]] && xfce_noblank "$pid"
        if have xset; then as_session "$pid" xset s off s noblank -dpms >/dev/null 2>&1 || true; fi
        n=$((n + 1))
        log "сеанс $user (PID $pid, $proc): гашение и DPMS выключены"
    done < <(graphical_sessions)
    ok "Гашение экрана X отключено ($X11_CONF_DIR/$XORG_NOBLANK; открытых сеансов обработано: $n)"
}

# «Разбудить» экран без потери сеанса: DPMS on + переключение виртуальных консолей
display_wake() {
    step "Пробуждение экрана"
    local pid user cur other
    while read -r pid user; do
        [[ -n $pid ]] || continue
        have xset && as_session "$pid" xset dpms force on s reset >/dev/null 2>&1 || true
    done < <(graphical_sessions)
    if have chvt && [[ -r $TTY_ACTIVE ]]; then
        cur=$(<"$TTY_ACTIVE"); cur=${cur#tty}
        if [[ $cur =~ ^[0-9]+$ ]]; then
            other=$(( cur == 6 ? 5 : 6 ))
            run chvt "$other"; [[ $DRY_RUN == 1 ]] || sleep 1; run chvt "$cur"
        fi
    fi
    ok "Экран разбужен (DPMS on, переключение VT). Не помогло — altctl display restart"
}

# Проверки перед перезапуском display manager
display_precheck() {
    local unit=$1 name=${1%.service} okk=0 free d
    if ! unit_exists "$name"; then bad "Юнит $unit не найден"; return 1; fi
    case $name in
        lightdm)
            if have lightdm && ! lightdm --show-config >/dev/null 2>&1; then
                bad "Конфигурация LightDM с ошибкой: lightdm --show-config"; okk=1
            fi ;;
        sddm)
            have sddm || { bad "Нет исполняемого файла sddm"; okk=1; } ;;
        gdm)
            have gdm || [[ -x /usr/sbin/gdm ]] || { bad "Нет исполняемого файла gdm"; okk=1; } ;;
    esac
    for d in /tmp /var; do
        free=$(free_mb "$d")
        if [[ -n $free ]] && (( free < 50 )); then bad "Мало места в $d (${free} МБ) — графика не стартует"; okk=1; fi
    done
    if [[ -d /tmp/.X11-unix ]] && [[ $(stat -c %a /tmp/.X11-unix 2>/dev/null) != 1777 ]]; then
        wrn "Неверные права /tmp/.X11-unix — исправляю (1777)"
        run chmod 1777 /tmp/.X11-unix
    fi
    if [[ -n $(apt_lock_holders) ]]; then
        bad "Идёт установка пакетов — дождитесь её окончания, затем перезапускайте графику"; okk=1
    fi
    return $okk
}

display_restart() {
    step "Перезапуск графики"
    local unit; unit=$(dm_unit)
    [[ -n $unit ]] || { bad "Display manager не найден (система без графики?)"; return 1; }
    display_precheck "$unit" || { bad "Перезапуск $unit отменён: исправьте ошибки выше"; return 1; }
    ok "Проверки перед перезапуском $unit пройдены"
    if profile_has display && x_installed && ! display_noblank_ok; then display_noblank; fi
    confirm "Будет перезапущен $unit: все графические сеансы закроются, несохранённые данные пропадут. Продолжить?" \
        || die "Отменено"
    # --no-block: если altctl запущен из графического терминала, он завершится вместе с сеансом
    run systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    run systemctl --no-block restart "$unit" || { bad "systemctl restart $unit завершился с ошибкой"; return 1; }
    if [[ -n ${DISPLAY:-} || $DRY_RUN == 1 ]]; then
        ok "Перезапуск $unit поставлен в очередь"
        return 0
    fi
    local w=0
    while (( w < 20 )); do
        systemctl is-active --quiet "$unit" && { ok "$unit перезапущен и работает"; return 0; }
        sleep 2; w=$((w + 2))
    done
    bad "$unit не поднялся за 20 с: journalctl -u ${unit%.service} -b -n 50; journalctl -b -t Xorg"
    return 1
}

display_doctor() {
    step "Графика"
    local unit def n=0 pid user
    unit=$(dm_unit)
    def=$(systemctl get-default 2>/dev/null || true)
    if [[ -z $unit ]]; then
        log "display manager не установлен (цель загрузки: ${def:-?})"
        return 0
    fi
    if systemctl is-active --quiet "$unit"; then ok "Display manager $unit работает"
    elif [[ $def == graphical.target ]]; then bad "Display manager $unit не работает — altctl display restart"
    else wrn "Display manager $unit не запущен (цель загрузки: ${def:-?})"; fi
    while read -r pid user; do [[ -n $pid ]] && n=$((n + 1)) && log "сеанс: $user (PID $pid)"; done < <(graphical_sessions)
    (( n == 0 )) && log "открытых графических сеансов нет"
    if display_noblank_ok; then ok "Гашение экрана X отключено ($XORG_NOBLANK)"
    elif profile_has display; then wrn "Профиль vm: экран X может гаснуть (DPMS) — altctl fix"
    fi
    return 0
}

cmd_display() {
    case "${1:-status}" in
        status)  display_doctor ;;
        wake)    display_wake ;;
        restart) display_restart ;;
        noblank) display_noblank ;;
        *)       die "altctl display [status|wake|restart|noblank]" ;;
    esac
}
