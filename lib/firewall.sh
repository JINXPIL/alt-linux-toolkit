# shellcheck shell=bash
# =============================================================================
# firewall.sh — межсетевой экран из настроек FW_* (IPv4 + IPv6).
# Правила собираются целиком и загружаются атомарно (iptables-restore),
# поэтому SSH не обрывается. Сохраняются в /etc/sysconfig/ip{,6}tables и
# поднимаются при загрузке собственной службой altctl-firewall.service —
# она не зависит от того, есть ли в конкретной версии ALT iptables.service.
# =============================================================================

FW_UNIT="altctl-firewall"

fw_norm_port() {
    local p=${1//-/:} a b
    if [[ $p =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]]; then
        a=$((10#${BASH_REMATCH[1]}))
        b=${BASH_REMATCH[3]:+$((10#${BASH_REMATCH[3]}))}
        (( a >= 1 && a <= 65535 )) || return 1
        if [[ -n $b ]]; then (( b >= a && b <= 65535 )) || return 1; echo "$a:$b"
        else echo "$a"; fi
    else
        return 1
    fi
}

fw_port_rules() {  # <tcp|udp> <порты...>
    local proto=$1 p n; shift
    for p in "$@"; do
        n=$(fw_norm_port "$p") || { bad "Некорректный порт в FW_${proto^^}_PORTS: $p"; return 1; }
        echo "-A INPUT -p $proto -m $proto --dport $n -m conntrack --ctstate NEW -j ACCEPT"
    done
}

fw_render() {  # <4|6>
    local v=$1 net forward
    forward=${FW_FORWARD^^}; [[ $forward == ACCEPT ]] || forward=DROP
    echo "# Создано altctl ($TS) из настроек FW_* — правьте /etc/altctl.conf и выполните: altctl firewall apply"
    echo "*filter"
    echo ":INPUT DROP [0:0]"
    echo ":FORWARD $forward [0:0]"
    echo ":OUTPUT ACCEPT [0:0]"
    echo "-A INPUT -i lo -j ACCEPT"
    echo "-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    if [[ $v == 6 ]]; then
        # ICMPv6 обязателен: без него не работают обнаружение соседей и PMTU
        echo "-A INPUT -p ipv6-icmp -j ACCEPT"
        echo "-A INPUT -d fe80::/64 -p udp -m udp --dport 546 -j ACCEPT"
    fi
    echo "-A INPUT -m conntrack --ctstate INVALID -j DROP"
    if [[ $v == 4 ]] && is_yes "$FW_ALLOW_PING"; then
        echo "-A INPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT"
    fi
    for net in $FW_TRUSTED_NETS; do
        if [[ $v == 4 && $net == *.* && $net != *:* ]] || [[ $v == 6 && $net == *:* ]]; then
            echo "-A INPUT -s $net -j ACCEPT"
        fi
    done
    # shellcheck disable=SC2086
    fw_port_rules tcp $FW_TCP_PORTS || return 1
    # shellcheck disable=SC2086
    fw_port_rules udp $FW_UDP_PORTS || return 1
    if is_yes "$FW_LOG_DROPS"; then
        echo "-A INPUT -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix \"altctl-drop: \" --log-level 4"
    fi
    echo "COMMIT"
}

# Чужие цепочки (Docker, libvirt, fail2ban, k8s) — полная перезагрузка filter их сотрёт
fw_foreign_chains() {
    iptables -S 2>/dev/null | grep -oE '^-N (DOCKER[^ ]*|LIBVIRT[^ ]*|KUBE[^ ]*|CNI[^ ]*|f2b-[^ ]*)' | cut -d' ' -f2 | sort -u | paste -sd' '
}

ensure_iptables() {
    have iptables-restore && return 0
    log "iptables не установлен — ставлю"
    prepare_install && pkg_install_any iptables >/dev/null && { [[ $DRY_RUN == 1 ]] || have iptables-restore; }
}

fw_write_unit() {
    local r4 r6
    r4=$(command -v iptables-restore || echo /sbin/iptables-restore)
    r6=$(command -v ip6tables-restore || echo /sbin/ip6tables-restore)
    write_file "$SYSTEMD_DIR/$FW_UNIT.service" 0644 <<EOF
[Unit]
Description=altctl firewall: iptables-restore из $SYSCONFIG_DIR/ip{,6}tables
Before=network-pre.target
Wants=network-pre.target
ConditionPathExists=$SYSCONFIG_DIR/iptables

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'exec $r4 < $SYSCONFIG_DIR/iptables'
ExecStart=-/bin/sh -c '[ -f $SYSCONFIG_DIR/ip6tables ] && exec $r6 < $SYSCONFIG_DIR/ip6tables || true'
ExecReload=/bin/sh -c 'exec $r4 < $SYSCONFIG_DIR/iptables'

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable "$FW_UNIT.service" >/dev/null 2>&1
}

fw_apply() {
    step "Межсетевой экран"
    ensure_iptables || { bad "iptables недоступен"; return 1; }

    local foreign
    foreign=$(fw_foreign_chains)
    if [[ -n $foreign ]] && ! is_yes "$FW_FORCE"; then
        bad "Найдены цепочки других программ ($foreign) — применение сотрёт их. Задайте FW_FORCE=yes, если уверены."
        return 1
    fi
    if [[ -n ${SSH_CONNECTION:-} ]] && ! grep -qw 22 <<<"$FW_TCP_PORTS" && [[ -z $FW_TRUSTED_NETS ]]; then
        confirm "Вы подключены по SSH, а порт 22 не открыт. Продолжить?" || die "Отменено"
    fi

    local tmp4 tmp6 v6=0
    tmp4=$(mk_tmp); tmp6=$(mk_tmp)
    fw_render 4 > "$tmp4" || return 1
    if is_yes "$FW_IPV6" && have ip6tables-restore && [[ -e /proc/net/if_inet6 ]]; then
        fw_render 6 > "$tmp6" || return 1
        v6=1
    fi

    iptables-restore --test < "$tmp4" || { bad "Ошибка в правилах IPv4 (iptables-restore --test)"; return 1; }
    if (( v6 )); then
        ip6tables-restore --test < "$tmp6" || { bad "Ошибка в правилах IPv6"; return 1; }
    fi

    if [[ $DRY_RUN != 1 ]]; then
        mkdir -p "$BACKUP_ROOT"
        iptables-save > "$BACKUP_ROOT/firewall-$TS.v4" 2>/dev/null || true
        (( v6 )) && { ip6tables-save > "$BACKUP_ROOT/firewall-$TS.v6" 2>/dev/null || true; }
    fi
    run iptables-restore < "$tmp4" || { bad "Не удалось загрузить правила IPv4"; return 1; }
    (( v6 )) && { run ip6tables-restore < "$tmp6" || wrn "Не удалось загрузить правила IPv6"; }

    write_file "$SYSCONFIG_DIR/iptables" 0600 < "$tmp4"
    (( v6 )) && write_file "$SYSCONFIG_DIR/ip6tables" 0600 < "$tmp6"
    fw_write_unit
    state_set firewall "$TS"
    ok "Межсетевой экран: TCP [${FW_TCP_PORTS:-—}] UDP [${FW_UDP_PORTS:-—}] доверенные [${FW_TRUSTED_NETS:-—}], IPv6: $( ((v6)) && echo да || echo нет)"
    log "Откат: iptables-restore < $BACKUP_ROOT/firewall-$TS.v4  или  altctl firewall off"
}

fw_policy() { iptables -S "${1:-INPUT}" 2>/dev/null | awk '$1 == "-P" { print $3; exit }'; }

fw_status() {
    step "Межсетевой экран"
    if ! have iptables; then log "iptables не установлен"; return 0; fi
    if [[ $EUID -ne 0 ]]; then log "состояние правил видно только root (sudo altctl doctor)"; return 0; fi
    local pol rules
    pol=$(fw_policy INPUT); rules=$(iptables -S INPUT 2>/dev/null | grep -c '^-A' || true)
    log "INPUT: политика ${pol:-?}, правил: $rules; FW_ENABLE=$FW_ENABLE"
    if [[ $pol == DROP ]]; then ok "Межсетевой экран активен (INPUT DROP, правил: $rules)"
    elif is_yes "$FW_ENABLE"; then wrn "FW_ENABLE=yes, но политика INPUT=$pol — выполните altctl firewall apply"
    else log "Межсетевой экран не включён (FW_ENABLE=no)"; fi
    unit_exists "$FW_UNIT" && log "$FW_UNIT.service: $(systemctl is-enabled "$FW_UNIT.service" 2>/dev/null)"
    return 0
}

fw_off() {
    step "Отключение межсетевого экрана"
    have iptables || { ok "iptables не установлен — отключать нечего"; return 0; }
    local t c
    for t in iptables ip6tables; do
        have "$t" || continue
        for c in INPUT FORWARD OUTPUT; do run "$t" -P "$c" ACCEPT; done
        [[ -z $(fw_foreign_chains) ]] && run "$t" -F
    done
    unit_exists "$FW_UNIT" && run systemctl disable "$FW_UNIT.service" >/dev/null 2>&1
    ok "Межсетевой экран отключён (всё разрешено). Включить снова: altctl firewall apply"
}

# Самовосстановление: правила должны быть загружены, если FW_ENABLE=yes
fw_check() {
    is_yes "$FW_ENABLE" || return 0
    have iptables || { fw_apply; return; }
    if [[ $(fw_policy INPUT) == DROP ]]; then
        ok "Межсетевой экран загружен"
    elif [[ -r $SYSCONFIG_DIR/iptables ]]; then
        wrn "Правила межсетевого экрана не загружены — восстанавливаю из $SYSCONFIG_DIR/iptables"
        run iptables-restore < "$SYSCONFIG_DIR/iptables"
        if [[ -r $SYSCONFIG_DIR/ip6tables ]] && have ip6tables-restore; then
            run ip6tables-restore < "$SYSCONFIG_DIR/ip6tables"
        fi
    else
        fw_apply
    fi
}

cmd_firewall() {
    case "${1:-status}" in
        apply)  fw_apply ;;
        status) fw_status ;;
        off)    fw_off ;;
        show)   fw_render 4; is_yes "$FW_IPV6" && { echo; fw_render 6; } ;;
        *)      die "altctl firewall [apply|status|off|show]" ;;
    esac
}
