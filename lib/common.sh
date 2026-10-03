# shellcheck shell=bash
# =============================================================================
# common.sh — вывод, dry-run, итоговая сводка, конфигурация, блокировка
# =============================================================================

# shellcheck disable=SC2034  # используется в altctl
ALTCTL_VERSION="1.3.0"
TS="$(date +%Y%m%d_%H%M%S)"
STAMP="$(date +%Y%m%d_%H%M%S_%N)"   # уникальное имя каталога резервной копии

# --- Пути (переопределяются окружением; используется в тестах) ---------------
: "${APT_ETC:=/etc/apt}"
: "${APT_STATE:=/var/lib/apt}"
: "${APT_CACHE:=/var/cache/apt}"
: "${RPM_DB:=/var/lib/rpm}"
: "${OS_RELEASE:=/etc/os-release}"
: "${ALT_RELEASE:=/etc/altlinux-release}"
: "${SYSCONFIG_DIR:=/etc/sysconfig}"
: "${SYSTEMD_DIR:=/etc/systemd/system}"
: "${BOOT_DIR:=/boot}"
: "${MODULES_DIR:=/lib/modules}"
: "${STATE_DIR:=/var/lib/altctl}"
: "${BACKUP_ROOT:=/var/backups/altctl}"
: "${LOCK_FILE:=/run/altctl.lock}"
: "${CHRONY_CONF:=/etc/chrony.conf}"
: "${X11_CONF_DIR:=/etc/X11/xorg.conf.d}"
: "${MODULES_LOAD_DIR:=/etc/modules-load.d}"
: "${PROC_DIR:=/proc}"
: "${DEV_DIR:=/dev}"
: "${SYS_PTP:=/sys/class/ptp}"
: "${DMI_DIR:=/sys/class/dmi/id}"
: "${CONSOLEBLANK_PARAM:=/sys/module/kernel/parameters/consoleblank}"
: "${TTY_ACTIVE:=/sys/class/tty/tty0/active}"
: "${PASSWD_FILE:=/etc/passwd}"
: "${GROUP_FILE:=/etc/group}"
: "${LOGIN_DEFS:=/etc/login.defs}"
: "${XDG_AUTOSTART_DIR:=/etc/xdg/autostart}"

# fd 3 — «журнал команд»: run/write_file пишут туда, поэтому вывод виден,
# даже когда сама команда вызвана с >/dev/null 2>&1
{ true >&3; } 2>/dev/null || exec 3>&2

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
declare -a SUMMARY=()
FAILS=0
WARNS=0

# --- Вывод -------------------------------------------------------------------
if [[ -t 2 ]]; then
    C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
    C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

log()  { printf '       %s\n' "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# Результаты проверок/действий — попадают в итоговую сводку
ok()  { SUMMARY+=("OK|$*");                    printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
wrn() { SUMMARY+=("WARN|$*"); WARNS=$((WARNS + 1)); printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
bad() { SUMMARY+=("FAIL|$*"); FAILS=$((FAILS + 1)); printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; }

print_summary() {
    (( ${#SUMMARY[@]} )) || return 0
    printf '\n%s==> Итог%s\n' "$C_B" "$C_0" >&2
    local line kind text color
    for line in "${SUMMARY[@]}"; do
        kind=${line%%|*}; text=${line#*|}
        case $kind in
            OK)   color=$C_G ;;
            WARN) color=$C_Y ;;
            *)    color=$C_R ;;
        esac
        printf '  %s%-4s%s  %s\n' "$color" "$kind" "$C_0" "$text" >&2
    done
    printf '  ошибок: %d, предупреждений: %d\n' "$FAILS" "$WARNS" >&2
}

# --- Выполнение --------------------------------------------------------------
# run: выполнить изменяющую команду (в режиме --dry-run только показать её)
run() {
    if [[ $DRY_RUN == 1 ]]; then
        { printf '%s  [dry-run]%s' "$C_D" "$C_0"; printf ' %q' "$@"; printf '\n'; } >&3
        return 0
    fi
    { printf '%s  $%s' "$C_D" "$C_0"; printf ' %q' "$@"; printf '\n'; } >&3
    "$@"
}

have()   { command -v "$1" >/dev/null 2>&1; }
is_yes() { [[ ${1,,} =~ ^(yes|y|1|true|on|да)$ ]]; }

need_root() {
    [[ $EUID -eq 0 || $DRY_RUN == 1 ]] || die "Нужны права root: sudo altctl $*"
}

confirm() {
    [[ $ASSUME_YES == 1 ]] && return 0
    [[ -t 0 ]] || return 1
    local a
    read -rp "$* [y/N] " a
    is_yes "$a"
}

acquire_lock() {
    [[ $DRY_RUN == 1 ]] && return 0
    have flock || return 0
    exec 9>"$LOCK_FILE" || die "Не удалось открыть $LOCK_FILE"
    flock -n 9 || die "altctl уже выполняется (блокировка $LOCK_FILE)"
}

unit_exists() {
    systemctl list-unit-files --no-legend "$1.service" "$1" 2>/dev/null \
        | grep -qE "^$1(\.service)?[[:space:]]"
}

# Резервная копия файла в $BACKUP_ROOT/<метка>-<время>/<исходный путь>
backup_file() {
    local tag=$1 f=$2 dst
    [[ -e $f ]] || return 0
    dst="$BACKUP_ROOT/$tag-$STAMP"
    if [[ $DRY_RUN == 1 ]]; then
        printf '%s  [dry-run] backup %s -> %s%s\n' "$C_D" "$f" "$dst" "$C_0" >&3
        return 0
    fi
    mkdir -p "$dst" && cp -a --parents "$f" "$dst/"
}

# Атомарная запись файла из stdin (в dry-run — показать содержимое)
write_file() {
    local path=$1 mode=${2:-0644} tmp
    if [[ $DRY_RUN == 1 ]]; then
        printf '%s  [dry-run] write %s:%s\n' "$C_D" "$path" "$C_0" >&3
        sed 's/^/      | /' >&3
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "$path.XXXXXX") || return 1
    cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"
}

# Временные файлы: каталог создаётся в altctl и удаляется при выходе
mk_tmp() { mktemp "${ALTCTL_TMP:-/tmp}/altctl.XXXXXX"; }

state_set() {
    [[ $DRY_RUN == 1 ]] && return 0
    mkdir -p "$STATE_DIR" && printf '%s\n' "$2" > "$STATE_DIR/$1"
}
state_get() { [[ -r $STATE_DIR/$1 ]] && cat "$STATE_DIR/$1"; }

# --- Конфигурация ------------------------------------------------------------
CONFIG_KEYS=(
    BRANCH MIRRORS MIRROR_SELECT MIRROR_TIMEOUT REPO_MULTILIB
    UPDATE_KERNEL REMOVE_OLD_KERNELS UPDATE_FLATPAK CLEAN_CACHE AUTO_REBOOT REBOOT_DELAY_MIN
    LOCK_WAIT WATCH_UNITS ROOT_MIN_FREE_MB BOOT_MIN_FREE_MB
    SERVICES
    FW_ENABLE FW_TCP_PORTS FW_UDP_PORTS FW_ALLOW_PING FW_TRUSTED_NETS FW_IPV6
    FW_FORWARD FW_LOG_DROPS FW_FORCE
    TIMER_SCHEDULE
    PROFILE TIME_SYNC TIME_MAX_OFFSET TIME_SYNC_WAIT TIME_HTTP_FALLBACK NTP_SERVERS
    VM_GUEST_TOOLS CLOCK_WATCH_INTERVAL GUEST_USERS GUEST_VBOXCLIENT
    REPO_HTTPS APT_NET_TUNING APT_PIPELINE_DEPTH APT_TIMEOUT APT_RETRIES
)

load_config() {
    local -A from_env=()
    local k f
    # значения, заданные в окружении, важнее файла конфигурации
    for k in "${CONFIG_KEYS[@]}"; do
        [[ -n ${!k+x} ]] && from_env[$k]=${!k}
    done

    CONFIG_FILE=""
    for f in "${ALTCTL_CONFIG:-}" /etc/altctl.conf "$ALTCTL_HOME/etc/altctl.conf"; do
        if [[ -n $f && -r $f ]]; then CONFIG_FILE=$f; break; fi
    done
    if [[ -n $CONFIG_FILE ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    for k in "${!from_env[@]}"; do printf -v "$k" '%s' "${from_env[$k]}"; done

    # значения по умолчанию
    : "${BRANCH:=auto}"
    : "${MIRRORS:=https://mirror.yandex.ru/altlinux https://mirror.truenetwork.ru/altlinux http://ftp.altlinux.org/pub/distributions/ALTLinux}"
    : "${MIRROR_SELECT:=fastest}"
    : "${MIRROR_TIMEOUT:=8}"
    : "${REPO_MULTILIB:=no}"
    : "${UPDATE_KERNEL:=yes}"
    : "${REMOVE_OLD_KERNELS:=yes}"
    : "${UPDATE_FLATPAK:=yes}"
    : "${CLEAN_CACHE:=yes}"
    : "${AUTO_REBOOT:=no}"
    : "${REBOOT_DELAY_MIN:=5}"
    : "${LOCK_WAIT:=300}"
    : "${WATCH_UNITS:=sshd}"
    : "${ROOT_MIN_FREE_MB:=1024}"
    : "${BOOT_MIN_FREE_MB:=150}"
    : "${SERVICES:=openssh-server:sshd}"
    : "${FW_ENABLE:=no}"
    : "${FW_TCP_PORTS:=22}"
    : "${FW_UDP_PORTS:=}"
    : "${FW_ALLOW_PING:=yes}"
    : "${FW_TRUSTED_NETS:=}"
    : "${FW_IPV6:=yes}"
    : "${FW_FORWARD:=DROP}"
    : "${FW_LOG_DROPS:=yes}"
    : "${FW_FORCE:=no}"
    : "${TIMER_SCHEDULE:=*-*-* 04:00}"
    : "${PROFILE:=auto}"
    : "${TIME_SYNC:=yes}"
    : "${TIME_MAX_OFFSET:=2}"
    : "${TIME_SYNC_WAIT:=20}"
    : "${TIME_HTTP_FALLBACK:=yes}"
    : "${NTP_SERVERS:=}"
    : "${VM_GUEST_TOOLS:=yes}"
    : "${CLOCK_WATCH_INTERVAL:=2min}"
    : "${GUEST_USERS:=auto}"
    : "${GUEST_VBOXCLIENT:=yes}"
    : "${REPO_HTTPS:=auto}"
    : "${APT_NET_TUNING:=yes}"
    : "${APT_PIPELINE_DEPTH:=0}"
    : "${APT_TIMEOUT:=30}"
    : "${APT_RETRIES:=3}"
}

is_alt() { [[ -r $ALT_RELEASE ]] || grep -qsE '^ID="?altlinux' "$OS_RELEASE"; }
