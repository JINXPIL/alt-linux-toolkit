# shellcheck shell=bash
# =============================================================================
# services.sh — установка пакетов и служб без привязки к версии:
#   * «a|b» — альтернативные имена пакета (первое доступное в репозитории);
#   * юниты службы можно не указывать — они берутся из файлов пакета (rpm -ql).
# =============================================================================

pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }
pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }

# pkg_install_any "a|b|c" -> ставит первый доступный, печатает выбранное имя
pkg_install_any() {
    local -a alts
    local a
    IFS='|' read -ra alts <<<"$1"
    for a in "${alts[@]}"; do
        pkg_installed "$a" && { echo "$a"; return 0; }
    done
    for a in "${alts[@]}"; do
        pkg_available "$a" || continue
        if run apt-get install -y "$a" >&2; then echo "$a"; return 0; fi
        log "установка $a не удалась — чиню зависимости и повторяю"
        run apt-get -f install -y >&2 || true
        if run apt-get install -y "$a" >&2; then echo "$a"; return 0; fi
    done
    return 1
}

# Systemd-службы, которые поставляет пакет
pkg_units() {
    rpm -ql "$1" 2>/dev/null \
        | grep -E '/systemd/system/[^/@]+\.service$' \
        | sed -E 's|.*/||; s|\.service$||' | sort -u
}

prepare_install() {
    heal_apt_locks || return 1
    if repo_needs_fix; then
        wrn "Источники пакетов: $REPO_PROBLEM — перенастраиваю"
        repo_auto || return 1
    fi
    lists_fresh || apt_update_resilient
}

cmd_install() {
    (( $# )) || die "Укажите пакеты: altctl install mc htop 'apache2-base|apache2'"
    step "Установка пакетов"
    prepare_install || return 1
    local spec name
    for spec in "$@"; do
        if name=$(pkg_install_any "$spec"); then ok "Пакет $name установлен"
        else bad "Не найден/не установился ни один из: $spec"; fi
    done
}

cmd_services() {
    step "Службы из SERVICES"
    [[ -n ${SERVICES// /} ]] || { log "SERVICES пуст — нечего делать"; return 0; }
    prepare_install || return 1
    local spec pkgspec units name u
    for spec in $SERVICES; do
        pkgspec=${spec%%:*}
        units=""
        [[ $spec == *:* ]] && units=${spec#*:}
        if ! name=$(pkg_install_any "$pkgspec"); then
            bad "Пакет не найден: $pkgspec"
            continue
        fi
        [[ -n $units ]] || units=$(pkg_units "$name" | paste -sd,)
        if [[ -z $units ]]; then
            ok "Пакет $name установлен (служб в нём нет)"
            continue
        fi
        for u in ${units//,/ }; do
            u=${u%.service}
            if ! unit_exists "$u" && [[ $DRY_RUN != 1 ]]; then
                wrn "У пакета $name нет службы $u — проверьте имя в SERVICES"
                continue
            fi
            if run systemctl enable --now "$u.service"; then ok "Служба $u ($name): включена и запущена"
            else bad "Служба $u не запустилась: journalctl -u $u -n 50"; fi
        done
    done
}
