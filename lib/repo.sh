# shellcheck shell=bash
# =============================================================================
# repo.sh — источники пакетов: выбор живого зеркала под текущую ветку и arch.
# Файл altctl пишет только в /etc/apt/sources.list.d/altctl.list, остальные
# активные строки комментирует (с резервной копией) — ветки не смешиваются.
# =============================================================================

ALTCTL_LIST_NAME="altctl.list"

branch_path() { if [[ $1 == Sisyphus ]]; then echo Sisyphus; else echo "$1/branch"; fi; }
branch_key()  { if [[ $1 == Sisyphus ]]; then echo alt; else echo "$1"; fi; }

key_available() {
    grep -hqs "simple-key \"$1\"" "$APT_ETC/vendors.list" "$APT_ETC"/vendors.list.d/* 2>/dev/null
}

# Время скачивания файла release с зеркала (сек) или код ошибки
mirror_probe() {
    local url s e
    url="${1%/}/$(branch_path "$2")/$3/base/release"
    if have curl; then
        curl -fsS -o /dev/null --max-time "$MIRROR_TIMEOUT" -w '%{time_total}' "$url" 2>/dev/null
    elif have wget; then
        s=$(date +%s%N)
        wget -q -T "$MIRROR_TIMEOUT" -t 1 -O /dev/null "$url" || return 1
        e=$(date +%s%N)
        awk -v d=$((e - s)) 'BEGIN { printf "%.3f", d / 1e9 }'
    else
        echo "0"   # нечем проверить — считаем доступным
    fi
}

# choose_mirror <ветка> <arch> [исключить] -> URL лучшего зеркала
choose_mirror() {
    local branch=$1 arch=$2 exclude=${3:-} m t best="" best_t=""
    for m in $MIRRORS; do
        m=${m%/}
        [[ -n $exclude && $m == "${exclude%/}" ]] && continue
        if t=$(mirror_probe "$m" "$branch" "$arch"); then
            log "зеркало $m — ответ за ${t} с"
            if [[ $MIRROR_SELECT == first ]]; then echo "$m"; return 0; fi
            if [[ -z $best ]] || awk -v a="$t" -v b="$best_t" 'BEGIN { exit !(a < b) }'; then
                best=$m; best_t=$t
            fi
        else
            log "зеркало $m — недоступно или нет ветки $branch/$arch"
        fi
    done
    [[ -n $best ]] && echo "$best"
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
