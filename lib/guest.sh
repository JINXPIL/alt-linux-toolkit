# shellcheck shell=bash
# =============================================================================
# guest.sh — гостевые дополнения гипервизоров (прежде всего VirtualBox).
#
# Модули ядра VirtualBox в ALT могут приходить из четырёх мест — altctl
# определяет источник сам и ведёт себя по-разному:
#   kernel — vboxguest/vboxsf входят в само ядро (kernel-image, mainline):
#            после update-kernel они уже есть в новом ядре;
#   alt    — пакет kernel-modules-virtualbox-addition-<тип ядра>:
#            update-kernel ставит его версию для нового ядра сам;
#   iso    — Guest Additions с образа VBoxGuestAdditions.iso (rcvboxadd,
#            vboxadd.service): модули собираются из исходников, нужны
#            kernel-headers-modules-<тип ядра>, gcc и make;
#   dkms   — модули собирает DKMS: нужны те же заголовки + dkms autoinstall.
# Заголовки в ALT называются по ТИПУ ядра (kernel-headers-modules-6.12,
# kernel-headers-modules-std-def), а не по `uname -r`.
#
# Также: группа vboxsf для общих папок (UID_MIN берётся из /etc/login.defs —
# в ALT обычные пользователи начинаются с 500, а не с 1000) и автозапуск
# VBoxClient (общий буфер обмена, подстройка размера экрана, drag-and-drop).
# =============================================================================

VBOX_GROUP="vboxsf"
VBOX_AUTOSTART="altctl-vboxclient.desktop"
GUEST_KERNEL_BROKEN=0

guest_tools_spec() {
    case $1 in
        oracle)    echo "virtualbox-guest-utils|virtualbox-guest-additions" ;;
        vmware)    echo "open-vm-tools" ;;
        kvm|qemu)  echo "qemu-guest-agent" ;;
        microsoft) echo "hyperv-daemons|hyperv-tools" ;;
    esac
}

# --- Пользователи и группа vboxsf --------------------------------------------
login_def() {
    local v
    v=$(awk -v k="$1" '$1 == k { print $2; exit }' "$LOGIN_DEFS" 2>/dev/null)
    echo "${v:-$2}"
}

# Обычные пользователи: UID_MIN..UID_MAX из login.defs, с рабочей оболочкой,
# плюс вошедшие в систему (loginctl) — например, доменные
guest_users() {
    if [[ ${GUEST_USERS,,} != auto ]]; then
        tr ' ' '\n' <<<"$GUEST_USERS" | grep -v '^$'
        return 0
    fi
    local min max
    min=$(login_def UID_MIN 1000); max=$(login_def UID_MAX 60000)
    {
        awk -F: -v a="$min" -v b="$max" \
            '$3 >= a && $3 <= b && $7 !~ /(nologin|false)$/ { print $1 }' "$PASSWD_FILE" 2>/dev/null
        if have loginctl; then
            loginctl list-users --no-legend 2>/dev/null | awk -v a="$min" -v b="$max" '$1 >= a && $1 <= b { print $2 }'
        fi
    } | sort -u
}

group_exists()  { grep -q "^$1:" "$GROUP_FILE" 2>/dev/null; }
group_members() { awk -F: -v g="$1" '$1 == g { gsub(/,/, " ", $4); print $4 }' "$GROUP_FILE" 2>/dev/null; }
user_in_group() {
    local m
    for m in $(group_members "$2"); do [[ $m == "$1" ]] && return 0; done
    return 1
}
users_missing_group() {
    local u
    while read -r u; do
        [[ -n $u ]] && ! user_in_group "$u" "$VBOX_GROUP" && echo "$u"
    done < <(guest_users)
}

vbox_group_fix() {
    if ! group_exists "$VBOX_GROUP"; then
        run groupadd -r "$VBOX_GROUP" || { bad "Не удалось создать группу $VBOX_GROUP"; return 1; }
        log "создана системная группа $VBOX_GROUP"
    fi
    local -a todo=() failed=()
    local u
    mapfile -t todo < <(users_missing_group)
    if (( ${#todo[@]} == 0 )); then
        ok "Общие папки: все пользователи ($(guest_users | paste -sd' ')) в группе $VBOX_GROUP"
        return 0
    fi
    for u in "${todo[@]}"; do
        run usermod -aG "$VBOX_GROUP" "$u" || failed+=("$u")
    done
    if (( ${#failed[@]} )); then bad "Не удалось добавить в $VBOX_GROUP: ${failed[*]}"; return 1; fi
    ok "Добавлены в группу $VBOX_GROUP: ${todo[*]} — доступ к общим папкам появится после повторного входа"
}

# --- Модули ядра --------------------------------------------------------------
module_loaded()     { awk -v m="$1" '$1 == m { f = 1 } END { exit !f }' "$PROC_DIR/modules" 2>/dev/null; }
kernel_has_module() { [[ -d $MODULES_DIR/$1 ]] && find "$MODULES_DIR/$1" -name "$2.ko*" -print -quit 2>/dev/null | grep -q .; }
headers_present()   { [[ -e $MODULES_DIR/$1/build/Makefile ]]; }

rcvboxadd_bin() {
    local p
    if p=$(command -v rcvboxadd 2>/dev/null); then echo "$p"; return 0; fi
    for p in /sbin/rcvboxadd /usr/sbin/rcvboxadd; do
        [[ -x $p ]] && { echo "$p"; return 0; }
    done
    return 1
}

vbox_module_source() {
    if rcvboxadd_bin >/dev/null; then echo iso
    elif have dkms && dkms status 2>/dev/null | grep -qiE 'vbox|virtualbox'; then echo dkms
    elif rpm -qa 'kernel-modules-virtualbox-addition*' 2>/dev/null | grep -q .; then echo alt
    elif kernel_has_module "$(running_kernel)" vboxguest; then echo kernel
    else echo none
    fi
}

vbox_source_title() {
    case $1 in
        iso)    echo "Guest Additions с ISO (модули собираются из исходников)" ;;
        dkms)   echo "DKMS (модули собираются из исходников)" ;;
        alt)    echo "пакет ALT kernel-modules-virtualbox-addition-<тип ядра>" ;;
        kernel) echo "встроены в ядро" ;;
        *)      echo "не найдены" ;;
    esac
}

# Заголовки и компилятор для сборки модулей под ядро <k>
vbox_build_deps() {
    local k=$1 hp
    hp="kernel-headers-modules-$(kernel_flavour_of "$k")"
    if ! headers_present "$k"; then
        if pkg_available "$hp"; then
            run apt-get install -y "$hp" >&2 || true
        else
            wrn "Пакет $hp не найден в репозитории — собрать модули VirtualBox для $k не получится"
        fi
    fi
    have gcc  || pkg_install_any gcc  >/dev/null || true
    have make || pkg_install_any make >/dev/null || true
}

# vbox_modules_ensure <ядро> — модули vboxguest/vboxsf должны быть для этого ядра
vbox_modules_ensure() {
    local k=$1 src pkg rc
    kernel_has_module "$k" vboxguest && return 0
    src=$(vbox_module_source)
    case $src in
        iso)
            vbox_build_deps "$k"
            rc=$(rcvboxadd_bin)
            if [[ $k == "$(running_kernel)" ]]; then run "$rc" setup >&2 || true
            else run "$rc" quicksetup "$k" >&2 || true; fi ;;
        dkms)
            vbox_build_deps "$k"
            run dkms autoinstall -k "$k" >&2 || true ;;
        *)
            pkg="kernel-modules-virtualbox-addition-$(kernel_flavour_of "$k")"
            if pkg_available "$pkg"; then run apt-get install -y "$pkg" >&2 || true; fi ;;
    esac
    [[ $DRY_RUN == 1 ]] && return 0
    kernel_has_module "$k" vboxguest
}

vbox_modules_load() {
    local m k; k=$(running_kernel)
    for m in vboxguest vboxsf; do
        if ! module_loaded "$m" && kernel_has_module "$k" "$m"; then
            run modprobe "$m" >/dev/null 2>&1 || wrn "modprobe $m завершился с ошибкой"
        fi
    done
}

# --- Службы -------------------------------------------------------------------
vbox_units() {
    systemctl list-unit-files --no-legend 'vbox*.service' 'virtualbox*.service' 2>/dev/null \
        | awk '{print $1}' | grep -v '@' | sed 's/\.service$//' | sort -u
}

vbox_services_fix() {
    local u started=()
    for u in $(vbox_units); do
        if ! systemctl is-active --quiet "$u.service" 2>/dev/null || ! systemctl is-enabled --quiet "$u.service" 2>/dev/null; then
            run systemctl enable --now "$u.service" >/dev/null 2>&1 && started+=("$u")
        fi
    done
    (( ${#started[@]} )) && ok "Службы VirtualBox включены: ${started[*]}"
    return 0
}

# --- VBoxClient: буфер обмена, экран, drag-and-drop ---------------------------
# Набор режимов определяется по `VBoxClient --help` установленной версии
vboxclient_opts() {
    have VBoxClient || return 1
    local help o=(--clipboard)
    help=$(VBoxClient --help 2>&1 || true)
    if module_loaded vmwgfx && grep -q -- '--vmsvga' <<<"$help"; then o+=(--vmsvga)
    elif grep -q -- '--display' <<<"$help"; then o+=(--display)
    elif grep -q -- '--vmsvga' <<<"$help"; then o+=(--vmsvga); fi
    grep -q -- '--draganddrop' <<<"$help" && o+=(--draganddrop)
    grep -q -- '--seamless' <<<"$help" && o+=(--seamless)
    echo "${o[*]}"
}

vboxclient_autostart_file() {
    local f
    for f in "$XDG_AUTOSTART_DIR"/*.desktop; do
        [[ -r $f ]] || continue
        if grep -q 'VBoxClient' "$f" && ! grep -qiE '^Hidden=true' "$f"; then echo "$f"; return 0; fi
    done
    return 1
}

vboxclient_autostart_render() {
    local opts cmd="" o
    if have VBoxClient-all; then
        cmd="VBoxClient-all"
    else
        opts=$(vboxclient_opts) || return 1
        for o in $opts; do cmd+="VBoxClient $o; "; done
        cmd="/bin/sh -c \"${cmd%; }\""
    fi
    cat <<EOF
[Desktop Entry]
Type=Application
Name=VirtualBox Guest Client
Comment=altctl: общий буфер обмена, подстройка размера экрана, drag-and-drop
TryExec=VBoxClient
Exec=$cmd
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
}

vboxclient_running() { pgrep -u "$1" -f -- "VBoxClient.*$2" >/dev/null 2>&1; }

# vboxclient_setup [restart] — автозапуск + запуск в открытых сеансах
vboxclient_setup() {
    local restart=${1:-no} f opts pid user opt
    is_yes "$GUEST_VBOXCLIENT" || return 0
    x_installed || return 0
    if ! have VBoxClient; then
        if [[ $DRY_RUN == 1 ]]; then log "VBoxClient появится после установки утилит"
        else wrn "VBoxClient не найден — буфер обмена работать не будет"; fi
        return 0
    fi
    if f=$(vboxclient_autostart_file); then
        ok "Автозапуск VBoxClient: ${f##*/}"
    else
        vboxclient_autostart_render | write_file "$XDG_AUTOSTART_DIR/$VBOX_AUTOSTART" 0644 \
            && ok "Автозапуск VBoxClient создан: $XDG_AUTOSTART_DIR/$VBOX_AUTOSTART"
    fi
    opts=$(vboxclient_opts)
    while read -r pid user; do
        [[ -n $pid ]] || continue
        if [[ $restart == yes ]]; then
            run pkill -u "$user" -x VBoxClient >/dev/null 2>&1 || true
            [[ $DRY_RUN == 1 ]] || sleep 1
        fi
        local -a started=()
        for opt in $opts; do
            if [[ $restart == yes ]] || ! vboxclient_running "$user" "$opt"; then
                as_session "$pid" VBoxClient "$opt" >/dev/null 2>&1 && started+=("$opt")
            fi
        done
        if (( ${#started[@]} )); then ok "VBoxClient в сеансе $user: ${started[*]}"; fi
    done < <(graphical_sessions)
}

# --- Установка ----------------------------------------------------------------
vbox_install() {
    local restart=${1:-no} name k xp="" p
    k=$(running_kernel)
    if name=$(pkg_install_any "virtualbox-guest-utils|virtualbox-guest-additions"); then
        ok "Утилиты гостя VirtualBox: $name"
    elif rcvboxadd_bin >/dev/null; then
        log "пакета утилит в репозитории нет, но установлены дополнения с ISO — использую их"
    else
        bad "Не найдены ни пакет virtualbox-guest-utils, ни дополнения с ISO"
        return 1
    fi
    if x_installed; then
        for p in xorg-extension-vboxguest xorg-drv-vboxvideo; do
            if pkg_installed "$p" || pkg_available "$p"; then xp=$p; break; fi
        done
        if [[ -n $xp ]]; then
            pkg_install_any "$xp" >/dev/null && ok "X-компонент VirtualBox: $xp"
        else
            log "отдельный X-драйвер не нужен: с видеоконтроллером VMSVGA работают modesetting + vmwgfx"
        fi
    fi
    if vbox_modules_ensure "$k"; then
        ok "Модули VirtualBox для ядра $k: $(vbox_source_title "$(vbox_module_source)")"
    else
        wrn "Модулей VirtualBox для ядра $k нет — буфер обмена и общие папки работать не будут"
    fi
    vbox_modules_load
    vbox_services_fix
    vbox_group_fix
    vboxclient_setup "$restart"
}

guest_tools_generic() {
    local virt=$1 spec name u units
    spec=$(guest_tools_spec "$virt")
    [[ -n $spec ]] || { log "Для $(virt_title "$virt") гостевые инструменты не предусмотрены"; return 0; }
    if ! name=$(pkg_install_any "$spec"); then
        wrn "Гостевые инструменты для $(virt_title "$virt") не найдены в репозитории ($spec)"
        return 0
    fi
    units=$(pkg_units "$name")
    for u in $units; do
        [[ $u == *@ ]] && continue
        run systemctl enable --now "$u.service" >/dev/null 2>&1 || true
    done
    if [[ $virt == vmware ]] && have vmware-toolbox-cmd; then
        run vmware-toolbox-cmd timesync enable >/dev/null 2>&1 || true
    fi
    ok "Гостевые инструменты $(virt_title "$virt"): $name${units:+ (службы: $(paste -sd' ' <<<"$units"))}"
}

# guest_install [restart] — для любого гипервизора
guest_install() {
    local virt; virt=$(detect_virt)
    step "Гостевые дополнения: $(virt_title "$virt")"
    if [[ $virt == none ]]; then log "Это не виртуальная машина — гостевые дополнения не нужны"; return 0; fi
    is_yes "$VM_GUEST_TOOLS" || { log "VM_GUEST_TOOLS=no — пропускаю"; return 0; }
    prepare_install || return 1
    if [[ $virt == oracle ]]; then vbox_install "${1:-no}"; else guest_tools_generic "$virt"; fi
}

# --- Самовосстановление (fix/maintain) ----------------------------------------
guest_heal() {
    [[ $(detect_virt) == oracle ]] && is_yes "$VM_GUEST_TOOLS" || return 0
    local -a p=()
    local pid user u
    if ! have VBoxService && ! rcvboxadd_bin >/dev/null; then p+=("утилиты не установлены"); fi
    module_loaded vboxguest || p+=("модуль vboxguest не загружен")
    [[ -n $(users_missing_group) ]] && p+=("пользователи вне группы $VBOX_GROUP")
    for u in $(vbox_units); do
        systemctl is-active --quiet "$u.service" 2>/dev/null || p+=("служба $u не работает")
    done
    if is_yes "$GUEST_VBOXCLIENT" && x_installed && have VBoxClient; then
        vboxclient_autostart_file >/dev/null || p+=("нет автозапуска VBoxClient")
        while read -r pid user; do
            [[ -n $pid ]] && ! vboxclient_running "$user" --clipboard && p+=("буфер обмена не запущен у $user")
        done < <(graphical_sessions)
    fi
    if (( ${#p[@]} == 0 )); then
        ok "Гостевые дополнения VirtualBox в порядке"
        return 0
    fi
    wrn "VirtualBox: $(printf '%s; ' "${p[@]}" | sed 's/; $//') — исправляю"
    prepare_install || return 1
    vbox_install no
}

# --- Обновление ядра ----------------------------------------------------------
# До update-kernel: для сборки из исходников нужны заголовки и компилятор
guest_kernel_prepare() {
    [[ $(detect_virt) == oracle ]] && is_yes "$VM_GUEST_TOOLS" || return 0
    case $(vbox_module_source) in
        iso|dkms) vbox_build_deps "$(running_kernel)" ;;
    esac
    return 0
}

# После update-kernel: в ядре, которое загрузится, должны быть модули VirtualBox
guest_kernel_verify() {
    local k=$1 src
    [[ $(detect_virt) == oracle ]] && is_yes "$VM_GUEST_TOOLS" || return 0
    [[ -n $k && $k != "$(running_kernel)" ]] || return 0
    if kernel_has_module "$k" vboxguest; then
        ok "Новое ядро $k: модули VirtualBox на месте"
        return 0
    fi
    wrn "В новом ядре $k нет модулей VirtualBox — подготавливаю"
    if vbox_modules_ensure "$k"; then
        ok "Модули VirtualBox для ядра $k готовы"
        return 0
    fi
    src=$(vbox_module_source)
    if [[ $src == iso ]] && headers_present "$k"; then
        wrn "Модули для $k соберёт vboxadd.service при первой загрузке (заголовки ядра установлены)"
        return 0
    fi
    # shellcheck disable=SC2034  # читается в reboot_handle (update.sh)
    GUEST_KERNEL_BROKEN=1
    bad "Для ядра $k нет модулей VirtualBox: после перезагрузки пропадут буфер обмена, общие папки и подстройка экрана. Выполните altctl guest fix или выберите прежнее ядро в меню загрузчика"
    return 1
}

# --- Диагностика --------------------------------------------------------------
vbox_versions() {
    have VBoxControl || return 0
    local g h
    g=$(VBoxControl --nologo --version 2>/dev/null | head -n1)
    h=$(VBoxControl --nologo guestproperty get /VirtualBox/HostInfo/VBoxVer 2>/dev/null | sed -n 's/^Value: //p')
    log "версия дополнений: ${g:-?}, VirtualBox на хосте: ${h:-?}"
    if [[ -n $g && -n $h ]]; then
        local gm hm
        gm=$(cut -d. -f1,2 <<<"${g%%[r_]*}"); hm=$(cut -d. -f1,2 <<<"$h")
        [[ $gm == "$hm" ]] || wrn "Дополнения $gm, а VirtualBox хоста $hm — функции могут работать нестабильно; обновите дополнения"
    fi
}

vbox_doctor() {
    local src u m k dk video miss mounts pid user n=0 f
    src=$(vbox_module_source); k=$(running_kernel)
    log "модули VirtualBox: $(vbox_source_title "$src")"
    vbox_versions

    # службы
    local units; units=$( { echo vboxadd; echo vboxadd-service; vbox_units; } | sort -u)
    for u in $units; do
        unit_exists "$u" || continue
        n=$((n + 1))
        if systemctl is-active --quiet "$u.service" 2>/dev/null; then ok "Служба $u.service работает"
        else wrn "Служба $u.service не работает — altctl guest fix"; fi
    done
    if (( n == 0 )); then
        if pgrep -x VBoxService >/dev/null 2>&1; then ok "VBoxService работает"
        else wrn "Служб VirtualBox нет и VBoxService не запущен — altctl guest install"; fi
    fi

    # модули ядра
    if module_loaded vboxguest; then ok "Модуль vboxguest загружен"
    else wrn "Модуль vboxguest не загружен — altctl guest fix"; fi
    if module_loaded vboxsf; then ok "Модуль vboxsf загружен"
    elif kernel_has_module "$k" vboxsf; then log "модуль vboxsf есть, загрузится при подключении общей папки"
    else wrn "Модуля vboxsf нет в ядре $k — общие папки недоступны"; fi
    if module_loaded vboxvideo; then video="vboxvideo"
    elif module_loaded vmwgfx; then video="vmwgfx (контроллер VMSVGA — vboxvideo не нужен)"
    fi
    if [[ -n $video ]]; then ok "Видеодрайвер: $video"
    else wrn "Не загружен ни vboxvideo, ни vmwgfx — выберите VMSVGA в настройках дисплея ВМ"; fi

    # группа vboxsf
    if ! group_exists "$VBOX_GROUP"; then
        wrn "Группы $VBOX_GROUP нет — altctl guest fix"
    else
        miss=$(users_missing_group | paste -sd' ')
        if [[ -z $miss ]]; then ok "Пользователи в группе $VBOX_GROUP: $(guest_users | paste -sd' ')"
        else wrn "Не в группе $VBOX_GROUP (Permission denied на общих папках): $miss — altctl guest fix"; fi
    fi
    mounts=$(awk '$3 == "vboxsf" { print $2 }' "$PROC_DIR/mounts" 2>/dev/null | paste -sd' ')
    log "подключённые общие папки: ${mounts:-нет}"

    # VBoxClient
    if x_installed && is_yes "$GUEST_VBOXCLIENT"; then
        if f=$(vboxclient_autostart_file); then ok "Автозапуск VBoxClient: ${f##*/}"
        else wrn "Нет автозапуска VBoxClient в $XDG_AUTOSTART_DIR — altctl guest fix"; fi
        while read -r pid user; do
            [[ -n $pid ]] || continue
            if vboxclient_running "$user" --clipboard; then ok "Общий буфер обмена работает (сеанс $user)"
            else wrn "Общий буфер обмена не запущен в сеансе $user — altctl guest fix"; fi
        done < <(graphical_sessions)
    fi

    # ядро, которое загрузится следующим
    if reboot_needed; then
        dk=$(default_kernel)
        if kernel_has_module "$dk" vboxguest; then ok "В новом ядре $dk модули VirtualBox есть"
        else bad "В новом ядре $dk нет модулей VirtualBox — до перезагрузки выполните altctl guest fix"; fi
    fi
    return 0
}

guest_status() {
    local virt name spec u
    virt=$(detect_virt)
    step "Гостевые дополнения: $(virt_title "$virt")"
    case $virt in
        none)   log "это не виртуальная машина" ;;
        oracle) vbox_doctor ;;
        *)
            spec=$(guest_tools_spec "$virt")
            name=""
            for u in ${spec//|/ }; do pkg_installed "$u" && name=$u; done
            if [[ -n $name ]]; then ok "Гостевые инструменты: $name"
            elif [[ -n $spec ]]; then wrn "Гостевые инструменты не установлены ($spec) — altctl guest install"; fi
            [[ -n $name ]] || return 0
            for u in $(pkg_units "$name"); do
                if systemctl is-active --quiet "$u.service" 2>/dev/null; then ok "Служба $u работает"
                else wrn "Служба $u не работает"; fi
            done ;;
    esac
    return 0
}

cmd_guest() {
    case "${1:-status}" in
        status)  guest_status ;;
        install) guest_install no ;;
        fix)     guest_install yes ;;
        *)       die "altctl guest [status|install|fix]" ;;
    esac
}
