# shellcheck shell=bash
# =============================================================================
# repo.sh — источники пакетов: выбор живого зеркала под текущую ветку и arch.
# Файл altctl пишет только в /etc/apt/sources.list.d/altctl.list, остальные
# активные строки комментирует (с резервной копией) — ветки не смешиваются.
#
# HTTPS в приоритете (REPO_HTTPS=auto): незашифрованный HTTP режут DPI-шейперы,
# 30-мегабайтные pkglist «зависают». Для каждого зеркала сначала пробуется
# https://, на http:// altctl переходит, только если TLS не работает.
# В ALT метод https для APT — отдельный пакет apt-https (+ ca-certificates):
# без него строка https:// ломает apt-get update, поэтому он ставится заранее.
#
# Сетевая устойчивость APT: /etc/apt/apt.conf.d/99altctl-network.conf
# (без конвейера запросов, тайм-аут, повторы) — см. apt_net_*.
# =============================================================================

ALTCTL_LIST_NAME="altctl.list"
APT_NET_CONF="99altctl-network.conf"
HTTPS_USABLE=1

branch_path() { if [[ $1 == Sisyphus ]]; then echo Sisyphus; else echo "$1/branch"; fi; }
branch_key()  { if [[ $1 == Sisyphus ]]; then echo alt; else echo "$1"; fi; }

key_available() {
    grep -hqs "simple-key \"$1\"" "$APT_ETC/vendors.list" "$APT_ETC"/vendors.list.d/* 2>/dev/null
}

url_scheme()    { if [[ $1 == *://* ]]; then echo "${1%%://*}"; else echo http; fi; }
url_host_path() { local u=${1%/}; echo "${u#*://}"; }

# url_probe <полный URL> — время загрузки (с) на stdout; код возврата — код curl
url_probe() {
    local url=$1 s e
    if have curl; then
        curl -fsS -o /dev/null --max-time "$MIRROR_TIMEOUT" -w '%{time_total}' "$url" 2>/dev/null
        return
    elif have wget; then
        s=$(date +%s%N)
        wget -q -T "$MIRROR_TIMEOUT" -t 1 -O /dev/null "$url" || return 1
        e=$(date +%s%N)
        awk -v d=$((e - s)) 'BEGIN { printf "%.3f", d / 1e9 }'
    else
        echo "0"   # нечем проверить — считаем доступным
    fi
}

# mirror_probe <база зеркала> <ветка> <arch>
mirror_probe() { url_probe "${1%/}/$(branch_path "$2")/$3/base/release"; }

# Понятная причина по коду curl
probe_reason() {
    case $1 in
        6)                         echo "DNS не разрешает имя" ;;
        7)                         echo "соединение отклонено" ;;
        22)                        echo "нет ветки/архитектуры на зеркале (HTTP 404)" ;;
        28)                        echo "тайм-аут ${MIRROR_TIMEOUT} с" ;;
        35)                        echo "ошибка TLS-рукопожатия" ;;
        51|58|59|60|77|83|90|91)   echo "проблема с сертификатом TLS (проверьте время: altctl time sync)" ;;
        *)                         echo "недоступно (код $1)" ;;
    esac
}

# --- Метод https для APT --------------------------------------------------------
apt_methods_dir() {
    if [[ -n ${APT_METHODS_DIR:-} ]]; then echo "$APT_METHODS_DIR"; return 0; fi
    local d
    d=$(apt-config shell D Dir::Bin::Methods/d 2>/dev/null | sed -n "s/^D='\(.*\)'$/\1/p")
    if [[ -n $d && -d $d ]]; then echo "${d%/}"; return 0; fi
    for d in /usr/lib64/apt/methods /usr/lib/apt/methods; do
        [[ -d $d ]] && { echo "$d"; return 0; }
    done
    return 1
}

apt_https_ready() { local d; d=$(apt_methods_dir) && [[ -x $d/https ]]; }

# Поставить apt-https, пока источники ещё на http (иначе ставить будет неоткуда)
ensure_apt_https() {
    apt_https_ready && return 0
    [[ ${REPO_HTTPS,,} == no ]] && return 1
    log "у APT нет метода https — ставлю apt-https и ca-certificates"
    if [[ $DRY_RUN == 1 ]]; then
        run apt-get install -y apt-https ca-certificates
        return 0
    fi
    [[ -n $(active_repo_lines) ]] || return 1
    lists_fresh || run apt-get update >/dev/null 2>&1 || true
    run apt-get install -y apt-https ca-certificates >&2 || true
    apt_https_ready
}

https_wanted() { [[ ${REPO_HTTPS,,} != no && $HTTPS_USABLE == 1 ]]; }

# pick_mirror <ветка> <arch> <исключить> <URL...> — лучший из переданных
pick_mirror() {
    local branch=$1 arch=$2 exclude=$3 u t rc best="" best_t=""; shift 3
    for u in "$@"; do
        [[ -n $exclude && $u == "${exclude%/}" ]] && continue
        if t=$(mirror_probe "$u" "$branch" "$arch"); then
            log "зеркало $u — ответ за ${t} с"
            if [[ $MIRROR_SELECT == first ]]; then echo "$u"; return 0; fi
            if [[ -z $best ]] || awk -v a="$t" -v b="$best_t" 'BEGIN { exit !(a < b) }'; then
                best=$u; best_t=$t
            fi
        else
            rc=$?
            log "зеркало $u — $(probe_reason "$rc")"
        fi
    done
    [[ -n $best ]] && echo "$best"
}

# choose_mirror <ветка> <arch> [исключить] -> URL лучшего зеркала.
# Сначала все HTTPS-варианты, HTTP — только если ни одно HTTPS не ответило.
choose_mirror() {
    local branch=$1 arch=$2 exclude=${3:-} m hp best
    local -a https_urls=() http_urls=()
    for m in $MIRRORS; do
        m=${m%/}
        case $(url_scheme "$m") in
            http|https)
                hp=$(url_host_path "$m")
                if https_wanted; then https_urls+=("https://$hp"); fi
                [[ ${REPO_HTTPS,,} == yes ]] || http_urls+=("http://$hp") ;;
            *)  http_urls+=("$m") ;;      # ftp://, file:// — как есть
        esac
    done
    if (( ${#https_urls[@]} )); then
        if best=$(pick_mirror "$branch" "$arch" "$exclude" "${https_urls[@]}"); then echo "$best"; return 0; fi
        (( ${#http_urls[@]} )) && log "по HTTPS не ответило ни одно зеркало — пробую HTTP"
    fi
    (( ${#http_urls[@]} )) || return 1
    pick_mirror "$branch" "$arch" "$exclude" "${http_urls[@]}"
}

repo_render() {
    local branch=$1 arch=$2 mirror=$3 key path
    key=$(branch_key "$branch"); path=$(branch_path "$branch")
    echo "# Создано altctl ($TS). Не правьте вручную: altctl repo auto | altctl repo set <ветка>"
    echo "rpm [$key] $mirror $path/$arch classic"
    echo "rpm [$key] $mirror $path/noarch classic"
    if [[ $arch == x86_64 ]] && is_yes "$REPO_MULTILIB"; then
        echo "rpm [$key] $mirror $path/x86_64-i586 classic"
    fi
}

repo_backup_all() {
    local f
    for f in "$APT_ETC/sources.list" "$APT_ETC"/sources.list.d/*.list; do
        [[ -e $f ]] && backup_file repo "$f"
    done
}

# Комментирует активные строки rpm во всех источниках, кроме altctl.list
repo_disable_others() {
    local f
    for f in "$APT_ETC/sources.list" "$APT_ETC"/sources.list.d/*.list; do
        [[ -r $f && ${f##*/} != "$ALTCTL_LIST_NAME" ]] || continue
        if grep -qE '^[[:space:]]*rpm(-src)?[[:space:]]' "$f"; then
            run sed -i -E 's/^([[:space:]]*rpm(-src)?[[:space:]])/#altctl# \1/' "$f"
            log "отключены строки в $f"
        fi
    done
}

repo_apply() {
    local branch=$1 arch=$2 mirror=$3 list="$APT_ETC/sources.list.d/$ALTCTL_LIST_NAME"
    local key; key=$(branch_key "$branch")
    if ! key_available "$key" && [[ $DRY_RUN != 1 ]]; then
        log "нет ключа подписи [$key] — пробую обновить alt-gpgkeys"
        run apt-get install -y alt-gpgkeys >/dev/null 2>&1 || true
    fi
    if ! key_available "$key"; then
        bad "В системе нет ключа подписи [$key] для ветки $branch (пакет alt-gpgkeys). Репозитории не изменены."
        return 1
    fi
    if [[ -r $list ]] && diff -q <(grep -v '^#' "$list") <(repo_render "$branch" "$arch" "$mirror" | grep -v '^#') >/dev/null \
       && [[ $(repo_branches) == "$branch" ]]; then
        ok "Репозитории актуальны: $branch/$arch @ $mirror"
        return 0
    fi
    repo_backup_all
    repo_disable_others
    repo_render "$branch" "$arch" "$mirror" | write_file "$list" 0644 || { bad "Не удалось записать $list"; return 1; }
    state_set repo "$branch $arch $mirror"
    ok "Репозитории: $branch/$arch @ $mirror (прежние сохранены, откат: altctl repo restore)"
}

# repo_auto [исключить_зеркало] — определить ветку, выбрать живое зеркало, применить
repo_auto() {
    local branch arch mirror
    branch=$(target_branch) || { bad "Не удалось определить ветку ALT. Задайте BRANCH в /etc/altctl.conf"; return 1; }
    arch=$(detect_arch)
    step "Репозитории: ветка $branch, архитектура $arch"
    HTTPS_USABLE=1
    if [[ ${REPO_HTTPS,,} != no ]] && ! ensure_apt_https; then
        HTTPS_USABLE=0
        wrn "APT пока не умеет HTTPS (не удалось поставить apt-https) — выбираю зеркало по HTTP"
    fi
    mirror=$(choose_mirror "$branch" "$arch" "${1:-}") || true
    if [[ -z $mirror ]]; then
        bad "Ни одно зеркало из MIRRORS не отдаёт $branch/$arch — проверьте сеть"
        return 1
    fi
    repo_apply "$branch" "$arch" "$mirror"
}

# Нужна ли перенастройка: нет строк, смесь веток или ветка не совпадает с системой
repo_needs_fix() {
    local branches target
    branches=$(repo_branches)
    [[ -z $branches ]] && { REPO_PROBLEM="нет активных источников"; return 0; }
    if (( $(wc -l <<<"$branches") > 1 )); then
        REPO_PROBLEM="смешаны ветки: $(paste -sd' ' <<<"$branches")"; return 0
    fi
    target=$(target_branch 2>/dev/null) || return 1
    if [[ $branches != "$target" ]]; then
        REPO_PROBLEM="источники на ветке $branches, а система — $target"; return 0
    fi
    return 1
}

repo_show() {
    local b arch _f line
    step "Источники пакетов"
    b=$(detect_branch || echo "? не определена")
    arch=$(detect_arch)
    log "ветка системы: ${b%% *} (по: ${b#* }), архитектура: $arch, BRANCH=$BRANCH"
    while IFS=$'\t' read -r _f line; do
        log "${_f#"$APT_ETC"/}: $line"
    done < <(active_repo_lines)
    if repo_needs_fix; then wrn "Источники: $REPO_PROBLEM — исправить: altctl repo auto"
    else ok "Источники: ветка $(repo_branches), $(current_mirror)"; fi
    repo_proto_doctor
    apt_net_doctor
}

repo_set() {
    local nb
    nb=$(normalize_branch "$1") || die "Неизвестная ветка: $1 (пример: p10, p11, Sisyphus)"
    local cur; cur=$(target_branch 2>/dev/null || echo "?")
    if [[ $nb != "$cur" ]]; then
        log "Смена ветки $cur -> $nb означает обновление всей системы (altctl update)."
        confirm "Переключить репозитории на $nb?" || die "Отменено"
    fi
    BRANCH=$nb
    repo_auto || return 1
    # запоминаем выбор, иначе следующее «auto» вернёт прежнюю ветку
    if [[ -n ${CONFIG_FILE:-} && -w $CONFIG_FILE ]] && grep -q '^BRANCH=' "$CONFIG_FILE"; then
        run sed -i -E "s/^BRANCH=.*/BRANCH=$nb/" "$CONFIG_FILE"
        log "В $CONFIG_FILE записано BRANCH=$nb (вернуть автоопределение: BRANCH=auto)"
    fi
}

repo_restore() {
    local last
    last=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'repo-*' 2>/dev/null | sort | tail -n1)
    [[ -n $last ]] || die "Резервных копий источников нет"
    step "Восстановление источников из $last"
    run rm -f "$APT_ETC/sources.list.d/$ALTCTL_LIST_NAME"
    run cp -a "$last$APT_ETC/." "$APT_ETC/"
    ok "Источники восстановлены из $last"
    [[ ${BRANCH,,} == auto ]] || log "Внимание: в настройках BRANCH=$BRANCH — следующий repo auto снова выберет эту ветку"
}

# --- Перевод на HTTPS -------------------------------------------------------------
# Базовые URL активных строк с http:// (по одному на URL, с путём для проверки)
repo_http_urls() {
    local _f line url
    while IFS=$'\t' read -r _f line; do
        url=$(repo_line_url "$line")
        [[ $url == http://* ]] && printf '%s\t%s\n' "$url" "$(repo_line_path "$line")"
    done < <(active_repo_lines) | sort -u -t$'\t' -k1,1
}

repo_https_urls() {
    local _f line
    while IFS=$'\t' read -r _f line; do
        [[ $(repo_line_url "$line") == https://* ]] && echo y
    done < <(active_repo_lines) | head -n1
}

# Заменить в активных строках файла URL по карте "старый=новый;..."
repo_rewrite_urls() {
    awk -v map="$2" '
        BEGIN { n = split(map, pairs, ";"); for (k = 1; k <= n; k++) { split(pairs[k], kv, "="); if (kv[1] != "") M[kv[1]] = kv[2] } }
        /^[[:space:]]*rpm(-src)?[[:space:]]/ {
            i = ($2 ~ /^\[/) ? 3 : 2
            if ($i in M) { p = index($0, $i); $0 = substr($0, 1, p - 1) M[$i] substr($0, p + length($i)) }
        }
        { print }' "$1"
}

# repo_https [cli|heal] — перевести http:// на https:// там, где зеркало умеет TLS.
# После правки — apt-get update; если он падает, источники откатываются.
repo_https() {
    local mode=${1:-cli} url path rc map="" f new
    local -a done_urls=() skipped=()
    step "Перевод источников на HTTPS"
    while IFS=$'\t' read -r url path; do
        [[ -n $url ]] || continue
        if url_probe "https://${url#http://}/$path/base/release" >/dev/null; then
            map+="$url=https://${url#http://};"
            done_urls+=("${url#http://}")
        else
            rc=$?
            skipped+=("${url#http://} ($(probe_reason "$rc"))")
        fi
    done < <(repo_http_urls)

    if [[ -z $map && ${#skipped[@]} -eq 0 ]]; then
        ok "Все активные источники уже используют HTTPS"
        return 0
    fi
    if [[ -z $map ]]; then
        if [[ $mode == heal ]]; then wrn "HTTPS недоступен для источников: ${skipped[*]} — остаются на HTTP"
        else bad "Ни один источник не отвечает по HTTPS: ${skipped[*]}"; fi
        return 1
    fi
    if ! ensure_apt_https; then
        if [[ $mode == heal ]]; then wrn "APT не умеет HTTPS: пакет apt-https не установился — источники остаются на HTTP"
        else bad "APT не умеет HTTPS: пакет apt-https не установлен и не ставится"; fi
        return 1
    fi

    repo_backup_all
    for f in "$APT_ETC/sources.list" "$APT_ETC"/sources.list.d/*.list; do
        [[ -r $f ]] || continue
        new=$(mk_tmp)
        repo_rewrite_urls "$f" "$map" > "$new"
        cmp -s "$new" "$f" || write_file "$f" 0644 < "$new"
    done

    if [[ $DRY_RUN != 1 ]]; then
        if ! run apt-get update; then
            wrn "apt-get update по HTTPS не прошёл — возвращаю прежние источники"
            local last
            last=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'repo-*' 2>/dev/null | sort | tail -n1)
            [[ -n $last ]] && run cp -a "$last$APT_ETC/." "$APT_ETC/"
            if [[ $mode == heal ]]; then wrn "HTTPS не заработал — источники возвращены на HTTP"
            else bad "HTTPS не заработал — источники возвращены на HTTP (журнал apt-get выше)"; fi
            return 1
        fi
    fi
    ok "Источники переведены на HTTPS: ${done_urls[*]}"
    (( ${#skipped[@]} )) && wrn "Остались на HTTP (нет TLS): ${skipped[*]}"
    return 0
}

# Для fix/maintain: незашифрованный HTTP переводится на HTTPS, если это возможно
repo_https_heal() {
    [[ ${REPO_HTTPS,,} == no ]] && return 0
    [[ -n $(repo_http_urls) ]] || return 0
    wrn "Источники используют незашифрованный HTTP — перевожу на HTTPS"
    repo_https heal || true
}

repo_proto_doctor() {
    local n_http
    n_http=$(repo_http_urls | wc -l)
    if (( n_http > 0 )); then
        wrn "Репозитории используют незашифрованный HTTP (рекомендуется HTTPS) — altctl repo https"
    elif [[ -n $(repo_https_urls) ]]; then
        ok "Репозитории используют HTTPS"
    fi
    if [[ -n $(repo_https_urls) ]] && ! apt_https_ready; then
        bad "Источники на HTTPS, но у APT нет метода https — apt-get install apt-https (или altctl repo auto)"
    fi
}

# --- Сетевая устойчивость APT --------------------------------------------------
apt_net_file() { echo "$APT_ETC/apt.conf.d/$APT_NET_CONF"; }

apt_net_render() {
    cat <<EOF
// Создано altctl: устойчивость загрузок APT к DPI-шейпингу, NAT и сетевым мостам ВМ.
// Не правьте вручную: значения APT_* в /etc/altctl.conf, затем: altctl repo tune
//   Pipeline-Depth 0 — без конвейера HTTP-запросов (рвётся на прокси, DPI и мостах ВМ)
//   Timeout          — разорвать «повисшее» соединение и повторить, а не ждать вечно
//   Retries          — повторить неудачную загрузку файла
Acquire::http::Pipeline-Depth "$APT_PIPELINE_DEPTH";
Acquire::https::Pipeline-Depth "$APT_PIPELINE_DEPTH";
Acquire::http::Timeout "$APT_TIMEOUT";
Acquire::https::Timeout "$APT_TIMEOUT";
Acquire::Retries "$APT_RETRIES";
EOF
}

apt_net_ok() { [[ -r $(apt_net_file) ]] && cmp -s <(apt_net_render) "$(apt_net_file)"; }

apt_net_apply() {
    if ! is_yes "$APT_NET_TUNING"; then log "APT_NET_TUNING=no — сетевые настройки APT не трогаю"; return 0; fi
    local f k
    for k in APT_PIPELINE_DEPTH APT_TIMEOUT APT_RETRIES; do
        [[ ${!k} =~ ^[0-9]+$ ]] || { bad "$k=${!k}: нужно целое число"; return 1; }
    done
    f=$(apt_net_file)
    if apt_net_ok; then ok "Сетевые настройки APT на месте ($APT_NET_CONF)"; return 0; fi
    backup_file aptconf "$f"
    apt_net_render | write_file "$f" 0644 || { bad "Не удалось записать $f"; return 1; }
    # apt должен прочитать конфигурацию, иначе любая команда apt-get сломается
    if [[ $DRY_RUN != 1 ]] && have apt-config && ! apt-config dump >/dev/null 2>&1; then
        run rm -f "$f"
        bad "apt-config не принял $f — файл удалён, APT работает с прежними настройками"
        return 1
    fi
    ok "Сетевые настройки APT: Pipeline-Depth $APT_PIPELINE_DEPTH, Timeout $APT_TIMEOUT с, Retries $APT_RETRIES ($f)"
}

apt_net_heal() {
    is_yes "$APT_NET_TUNING" || return 0
    if apt_net_ok; then ok "Сетевые настройки APT на месте"; return 0; fi
    wrn "Сетевые настройки APT отсутствуют или изменены — восстанавливаю"
    apt_net_apply
}

apt_net_doctor() {
    is_yes "$APT_NET_TUNING" || { log "сетевые настройки APT отключены (APT_NET_TUNING=no)"; return 0; }
    if apt_net_ok; then ok "Сетевые настройки APT: $APT_NET_CONF"
    else wrn "Нет сетевых настроек APT ($(apt_net_file)) — altctl repo tune"; fi
}
