# shellcheck shell=bash
# =============================================================================
# detect.sh — определение ветки, архитектуры, ядра и состояния репозиториев.
# Ничего не захардкожено под конкретную версию: всё читается из системы.
# =============================================================================

os_field() {
    [[ -r $OS_RELEASE ]] || return 1
    sed -n "s/^$1=//p" "$OS_RELEASE" | head -n1 | tr -d '"'"'"
}

# Приводит имя ветки к виду, принятому на зеркалах: Sisyphus, p10, p11, c10f2 ...
normalize_branch() {
    local b=${1,,}
    case $b in
        sisyphus)                echo Sisyphus ;;
        p[0-9]|p[0-9][0-9])      echo "$b" ;;
        c[0-9]*)                 [[ $b =~ ^c[0-9]{1,2}(f[0-9])?$ ]] && echo "$b" || return 1 ;;
        *)                       return 1 ;;
    esac
}

# Печатает: "<ветка> <откуда взята>"
detect_branch() {
    local b v txt
    # 1. os-release: ALT_BRANCH_ID (современные выпуски)
    if b=$(normalize_branch "$(os_field ALT_BRANCH_ID)"); then
        echo "$b os-release:ALT_BRANCH_ID"; return 0
    fi
    # 2. /etc/altlinux-release: «ALT Sisyphus», «ALT p10 ...», «c10f2»
    if [[ -r $ALT_RELEASE ]]; then
        txt=$(<"$ALT_RELEASE")
        if [[ $txt =~ [Ss]isyphus ]]; then echo "Sisyphus altlinux-release"; return 0; fi
        if [[ $txt =~ (^|[^[:alnum:]])(p[0-9]{1,2}|c[0-9]{1,2}(f[0-9])?)([^[:alnum:]]|$) ]]; then
            echo "${BASH_REMATCH[2]} altlinux-release"; return 0
        fi
    fi
    # 3. VERSION_ID: 20240101 -> Sisyphus, 10.4 -> p10, 11.0 -> p11
    v=$(os_field VERSION_ID || true)
    if [[ $v =~ ^[0-9]{8}$ ]]; then echo "Sisyphus os-release:VERSION_ID"; return 0; fi
    if [[ $v =~ ^([0-9]{1,2})(\.|$) ]] && (( BASH_REMATCH[1] >= 8 )); then
        echo "p${BASH_REMATCH[1]} os-release:VERSION_ID"; return 0
    fi
    # 4. макрос rpm (есть не во всех выпусках)
    if b=$(normalize_branch "$(rpm --eval '%{?_priority_distbranch}' 2>/dev/null)"); then
        echo "$b rpm:_priority_distbranch"; return 0
    fi
    # 5. текущие источники пакетов
    b=$(repo_branches | head -n1)
    if [[ -n $b ]]; then echo "$b sources.list"; return 0; fi
    return 1
}

# Целевая ветка: из конфигурации или автоопределение
target_branch() {
    local b
    if [[ ${BRANCH,,} != auto ]]; then
        normalize_branch "$BRANCH" || { bad "Неизвестная ветка BRANCH=$BRANCH"; return 1; }
        return 0
    fi
    b=$(detect_branch) || return 1
    echo "${b%% *}"
}

detect_arch() {
    local a
    a=$(rpm --eval '%_arch' 2>/dev/null || true)
    [[ -z $a || $a == %* ]] && a=$(uname -m)
    case $a in
        i?86)   a=i586 ;;
        armv7*) a=armh ;;
    esac
    echo "$a"
}

# --- Ядро --------------------------------------------------------------------
running_kernel() { uname -r; }

# Ядро, которое загрузится по умолчанию: цель ссылки /boot/vmlinuz, иначе самое новое
default_kernel() {
    local t f best=""
    if [[ -L $BOOT_DIR/vmlinuz ]]; then
        t=$(readlink "$BOOT_DIR/vmlinuz"); t=${t##*/}
        echo "${t#vmlinuz-}"; return 0
    fi
    for f in "$BOOT_DIR"/vmlinuz-*; do
        [[ -e $f ]] || continue
        best+="${f##*/vmlinuz-}"$'\n'
    done
    [[ -n $best ]] && printf '%s' "$best" | sort -V | tail -n1
}

installed_kernels_count() {
    local n=0 f
    for f in "$BOOT_DIR"/vmlinuz-*; do [[ -e $f ]] && n=$((n + 1)); done
    echo "$n"
}

kernel_flavour() { uname -r | sed -nE 's/^[0-9.]+-(.+)-alt[0-9]+.*/\1/p'; }

in_container() { have systemd-detect-virt && systemd-detect-virt -cq 2>/dev/null; }

reboot_needed() {
    in_container && return 1
    local d
    d=$(default_kernel)
    [[ -n $d && $d != "$(running_kernel)" ]]
}

# --- Репозитории -------------------------------------------------------------
# Активные строки rpm во всех источниках, формат «файл<TAB>строка»
active_repo_lines() {
    local f
    for f in "$APT_ETC/sources.list" "$APT_ETC"/sources.list.d/*.list; do
        [[ -r $f ]] || continue
        grep -E '^[[:space:]]*rpm(-src)?[[:space:]]' "$f" | sed "s|^[[:space:]]*|$f\t|" || true
    done
}

# Поля строки «rpm [ключ] URL путь компонент»
repo_line_url()  { awk '{ i = ($2 ~ /^\[/) ? 3 : 2; print $i }' <<<"$1"; }
repo_line_path() { awk '{ i = ($2 ~ /^\[/) ? 3 : 2; print $(i + 1) }' <<<"$1"; }

repo_line_branch() {
    local p
    p=$(repo_line_path "$1")
    case $p in
        [Ss]isyphus/*) echo Sisyphus ;;
        */branch/*)    echo "${p%%/*}" ;;
        *)             return 1 ;;
    esac
}

repo_branches() {
    local _f line
    while IFS=$'\t' read -r _f line; do
        repo_line_branch "$line" || true
    done < <(active_repo_lines) | sort -u
}

current_mirror() {
    local _f line
    while IFS=$'\t' read -r _f line; do
        repo_line_url "$line"; return 0
    done < <(active_repo_lines)
}
