# shellcheck shell=bash
# =============================================================================
# power.sh — сон системы и гашение консоли.
#
# В ВМ попытка гостя уйти в suspend/hibernate или погасить экран часто
# заканчивается чёрным экраном: гипервизор не «будит» виртуальную видеокарту,
# LightDM/Xorg/xfdesktop падают или висят. Поэтому в профилях vm и server:
#   * sleep/suspend/hibernate/hybrid-sleep(/suspend-then-hibernate).target
#     маскируются — systemd физически не сможет усыпить систему;
#   * в /etc/sysconfig/console ставится BLANK_TIME=0 и POWERDOWN_TIME=0,
#     а в работающей системе гашение отключается сразу (setterm).
# Вернуть как было: altctl power allow-sleep
# =============================================================================

SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)

existing_sleep_targets() {
    local t
    for t in "${SLEEP_TARGETS[@]}"; do
        unit_exists "$t" && echo "$t"
    done
}

unit_state() { systemctl is-enabled "$1" 2>/dev/null | head -n1; }

sleep_masked() {
    local t
    while read -r t; do
        [[ -z $t ]] && continue
        [[ $(unit_state "$t") == masked ]] || return 1
    done < <(existing_sleep_targets)
    return 0
}

power_nosleep() {
    local -a todo=()
    local t
    while read -r t; do
        [[ -n $t && $(unit_state "$t") != masked ]] && todo+=("$t")
    done < <(existing_sleep_targets)
    if (( ${#todo[@]} == 0 )); then
        ok "Спящие режимы уже отключены (targets замаскированы)"
        return 0
    fi
    if run systemctl mask "${todo[@]}" >/dev/null 2>&1; then
        ok "Спящие режимы отключены: ${todo[*]}"
    else
        bad "Не удалось замаскировать ${todo[*]}"
    fi
}

power_allow_sleep() {
    local -a targets=()
    mapfile -t targets < <(existing_sleep_targets)
    (( ${#targets[@]} )) || { ok "Спящих targets нет"; return 0; }
    run systemctl unmask "${targets[@]}" >/dev/null 2>&1
    ok "Спящие режимы снова разрешены (${targets[*]}). Учтите: в профиле vm/server fix/maintain отключат их опять — задайте PROFILE=desktop"
}

# --- Консоль ------------------------------------------------------------------
console_file() { echo "$SYSCONFIG_DIR/console"; }

console_value() { sed -n "s/^[[:space:]]*$1=//p" "$(console_file)" 2>/dev/null | tail -n1 | tr -d '"'"'"; }

console_noblank_ok() {
    [[ $(console_value BLANK_TIME) == 0 && $(console_value POWERDOWN_TIME) == 0 ]] || return 1
    local cur
    cur=$(cat "$CONSOLEBLANK_PARAM" 2>/dev/null || echo 0)
    [[ $cur == 0 ]]
}

console_noblank() {
    local f new key
    f=$(console_file)
    new=$(mk_tmp)
    [[ -r $f ]] && cat "$f" > "$new"
    for key in BLANK_TIME POWERDOWN_TIME; do
        if grep -qE "^[[:space:]]*#?[[:space:]]*$key=" "$new"; then
            sed -i -E "s/^[[:space:]]*#?[[:space:]]*$key=.*/$key=0/" "$new"
        else
            echo "$key=0" >> "$new"
        fi
    done
    if ! cmp -s "$new" "$f"; then
        backup_file console "$f"
        write_file "$f" 0644 < "$new" || { bad "Не удалось записать $f"; return 1; }
    fi

    # применить сразу: интервал гашения в ядре общий для всех виртуальных консолей
    local tty
    if have setterm; then
        for tty in "$DEV_DIR"/tty{2,3,4,5,6,1}; do
            [[ -c $tty || $DRY_RUN == 1 ]] || continue
            if [[ $DRY_RUN == 1 ]]; then
                run setterm --blank 0 --powerdown 0; break
            fi
            # shellcheck disable=SC2094  # setterm читает и пишет один и тот же терминал — так и задумано
            TERM=linux setterm --blank 0 --powerdown 0 > "$tty" < "$tty" 2>/dev/null && break
        done
    fi
    ok "Гашение консоли отключено (BLANK_TIME=0, POWERDOWN_TIME=0 в $f)"
}

power_doctor() {
    step "Сон и консоль"
    local t st masked=() active=() p
    p=$(active_profile)
    while read -r t; do
        [[ -n $t ]] || continue
        st=$(unit_state "$t")
        if [[ $st == masked ]]; then masked+=("$t"); else active+=("$t($st)"); fi
    done < <(existing_sleep_targets)
    if (( ${#active[@]} == 0 )); then
        ok "Спящие режимы замаскированы: ${masked[*]:-—}"
    elif profile_has nosleep; then
        wrn "Профиль $p: спящие режимы не отключены: ${active[*]} — altctl fix"
    else
        log "спящие режимы разрешены (профиль $p): ${active[*]}"
    fi

    local b pd kb
    b=$(console_value BLANK_TIME); pd=$(console_value POWERDOWN_TIME)
    kb=$(cat "$CONSOLEBLANK_PARAM" 2>/dev/null || echo '?')
    log "$(console_file): BLANK_TIME=${b:-не задан}, POWERDOWN_TIME=${pd:-не задан}; ядро consoleblank=$kb с"
    if console_noblank_ok; then ok "Гашение консоли отключено"
    elif profile_has console; then wrn "Профиль $p: консоль может гаснуть — altctl fix"
    fi
    return 0
}

cmd_power() {
    case "${1:-status}" in
        status)       power_doctor ;;
        nosleep)      power_nosleep; console_noblank ;;
        allow-sleep)  power_allow_sleep ;;
        *)            die "altctl power [status|nosleep|allow-sleep]" ;;
    esac
}
