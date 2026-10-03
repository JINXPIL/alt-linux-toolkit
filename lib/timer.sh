# shellcheck shell=bash
# =============================================================================
# timer.sh — автоматическое обслуживание по расписанию (systemd timer).
# Юниты генерируются с актуальным путём к altctl и расписанием TIMER_SCHEDULE.
# =============================================================================

TIMER_UNIT="altctl-maintain"

timer_on() {
    step "Таймер обслуживания"
    local exe
    exe=$(readlink -f "$ALTCTL_HOME/altctl")
    if have systemd-analyze && ! systemd-analyze calendar "$TIMER_SCHEDULE" >/dev/null 2>&1; then
        die "Неверное расписание TIMER_SCHEDULE='$TIMER_SCHEDULE' (см. man systemd.time)"
    fi

    write_file "$SYSTEMD_DIR/$TIMER_UNIT.service" 0644 <<EOF
[Unit]
Description=altctl: самовосстановление и обновление ALT Linux
Wants=network-online.target
After=network-online.target
# на ноутбуке — только от сети (на ПК без батареи условие всегда истинно)
ConditionACPower=true

[Service]
Type=oneshot
ExecStart=$exe --yes maintain
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=3h
EOF
    write_file "$SYSTEMD_DIR/$TIMER_UNIT.timer" 0644 <<EOF
[Unit]
Description=altctl: расписание обслуживания ($TIMER_SCHEDULE)

[Timer]
OnCalendar=$TIMER_SCHEDULE
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    run systemctl daemon-reload
    if run systemctl enable --now "$TIMER_UNIT.timer"; then
        ok "Таймер включён: $TIMER_SCHEDULE (+ до 30 мин случайно; пропущенный запуск выполнится после включения ПК)"
    else
        bad "Не удалось включить $TIMER_UNIT.timer"
    fi
}

timer_off() {
    step "Таймер обслуживания"
    run systemctl disable --now "$TIMER_UNIT.timer" >/dev/null 2>&1 || true
    ok "Таймер выключен (юниты оставлены; удалить: rm $SYSTEMD_DIR/$TIMER_UNIT.*)"
}

timer_status() {
    step "Таймер обслуживания"
    if ! unit_exists "$TIMER_UNIT.timer"; then
        log "Таймер не установлен: altctl timer on"
        return 0
    fi
    systemctl list-timers --all --no-pager "$TIMER_UNIT.timer" 2>/dev/null | sed 's/^/       /' >&2
    local res
    res=$(systemctl show -p Result --value "$TIMER_UNIT.service" 2>/dev/null)
    log "последний запуск: ${res:-нет данных}; журнал: journalctl -u $TIMER_UNIT -n 100"
    if systemctl is-enabled --quiet "$TIMER_UNIT.timer" 2>/dev/null; then ok "Таймер обслуживания включён"
    else wrn "Таймер обслуживания установлен, но выключен"; fi
}

cmd_timer() {
    case "${1:-status}" in
        on)     timer_on ;;
        off)    timer_off ;;
        status) timer_status ;;
        *)      die "altctl timer [on|off|status]" ;;
    esac
}
