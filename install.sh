#!/usr/bin/env bash
# =============================================================================
# install.sh — установка altctl в систему
#
#   sudo ./install.sh              установить/обновить + включить ежедневный таймер
#   sudo ./install.sh --no-timer   установить без таймера
#   sudo ./install.sh --uninstall  удалить (настройки и резервные копии остаются)
#
# Куда ставится:
#   /opt/altctl/            программа (altctl + lib/)
#   /usr/local/sbin/altctl  ссылка для запуска
#   /etc/altctl.conf        настройки (существующий файл не перезаписывается)
# =============================================================================
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/altctl
LINK=/usr/local/sbin/altctl
CONF=/etc/altctl.conf

[[ $EUID -eq 0 ]] || { echo "Нужны права root: sudo $0 $*" >&2; exit 1; }

uninstall() {
    [[ -x $LINK ]] && "$LINK" timer off >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/altctl-maintain.{service,timer}
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$LINK" /usr/local/bin/altctl
    rm -rf "$DEST"
    echo "altctl удалён. Оставлены: $CONF, /var/backups/altctl, /var/lib/altctl,"
    echo "межсетевой экран (если включали): altctl-firewall.service — отключить до удаления: altctl firewall off"
}

install_files() {
    # при запуске из уже установленной копии копировать нечего
    if [[ $(readlink -f "$SRC") != "$(readlink -f "$DEST")" ]]; then
        rm -rf "$DEST.new"
        mkdir -p "$DEST.new"
        cp -r "$SRC/altctl" "$SRC/lib" "$SRC/etc" "$DEST.new/"
        [[ -f $SRC/install.sh ]] && cp "$SRC/install.sh" "$DEST.new/"
        rm -rf "$DEST"
        mv "$DEST.new" "$DEST"
    fi
    # окончания строк Windows (CRLF) ломают bash — убираем на всякий случай
    find "$DEST" -type f \( -name '*.sh' -o -name altctl -o -name '*.conf' \) -exec sed -i 's/\r$//' {} +
    chmod 0755 "$DEST/altctl" "$DEST"/install.sh 2>/dev/null || true
    chmod 0644 "$DEST"/lib/*.sh
    ln -sfn "$DEST/altctl" "$LINK"
    # /usr/local/sbin есть не во всех PATH (sudo secure_path) — дублируем в /usr/local/bin
    ln -sfn "$DEST/altctl" /usr/local/bin/altctl

    if [[ -f $CONF ]]; then
        if ! cmp -s "$DEST/etc/altctl.conf" "$CONF"; then
            cp "$DEST/etc/altctl.conf" "$CONF.new"
            echo "Настройки $CONF сохранены; новый образец: $CONF.new"
        fi
    else
        install -m 0644 "$DEST/etc/altctl.conf" "$CONF"
        echo "Создан $CONF"
    fi
    echo "altctl установлен: $LINK -> $DEST/altctl"
}

case ${1:-} in
    --uninstall) uninstall ;;
    --no-timer)  install_files; "$LINK" doctor || true ;;
    "")          install_files; "$LINK" --yes timer on; "$LINK" doctor || true ;;
    *)           echo "Использование: sudo $0 [--no-timer|--uninstall]" >&2; exit 1 ;;
esac
