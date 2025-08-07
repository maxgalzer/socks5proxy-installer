#!/bin/bash
set -e

REPO_NAME="socks5proxy-installer"
SCRIPT_NAME="socks5proxy-installer.sh"
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
USERFILE="/etc/3proxy/users.lst"
SYSTEMD_FILE="/etc/systemd/system/3proxy.service"

function print_green() { echo -e "\e[32m$1\e[0m"; }
function print_red() { echo -e "\e[31m$1\e[0m"; }
function pause() { read -p "Нажмите Enter для продолжения..."; }

function install_deps() {
    print_green "Установка зависимостей..."
    apt update
    apt install -y git gcc make libc6 libevent-dev libssl-dev wget curl build-essential python3 python3-pip
    pip3 install --upgrade pysocks >/dev/null 2>&1 || true
}

function install_3proxy() {
    if command -v 3proxy &>/dev/null; then
        print_green "3proxy уже установлен."
        return
    fi

    print_green "Клонируем и собираем 3proxy..."
    cd /tmp
    rm -rf 3proxy
    git clone --depth=1 https://github.com/z3APA3A/3proxy.git
    cd 3proxy
    make -f Makefile.Linux

    # Копируем бинарник из src/ или bin/
    if [[ -f ./src/3proxy ]]; then
        cp ./src/3proxy /usr/local/bin/
    elif [[ -f ./bin/3proxy ]]; then
        cp ./bin/3proxy /usr/local/bin/
    else
        print_red "❌ Не найден собранный бинарник 3proxy. Проверьте ошибки make!"
        exit 1
    fi

    mkdir -p /etc/3proxy/logs
    mkdir -p /etc/3proxy/
    chmod +x /usr/local/bin/3proxy
    cd ~
}

function ask_creds() {
    read -p "Введите порт для SOCKS5 (например, 1080): " PROXY_PORT
    while ! [[ "$PROXY_PORT" =~ ^[0-9]{2,5}$ ]]; do
        print_red "Порт должен быть числом!"
        read -p "Введите порт для SOCKS5: " PROXY_PORT
    done

    read -p "Введите логин: " PROXY_USER
    while [[ -z "$PROXY_USER" ]]; do
        print_red "Логин не должен быть пустым!"
        read -p "Введите логин: " PROXY_USER
    done

    read -s -p "Введите пароль: " PROXY_PASS
    echo
    while [[ -z "$PROXY_PASS" ]]; do
        print_red "Пароль не должен быть пустым!"
        read -s -p "Введите пароль: " PROXY_PASS
        echo
    done
}

function write_config() {
    print_green "Создание конфига 3proxy..."
    cat <<EOF > "$CONFIG_FILE"
daemon
nserver 8.8.8.8
nserver 1.1.1.1
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /etc/3proxy/logs/3proxy.log D
users $(cat $USERFILE | tr '\n' ',')
auth strong
allow * *
socks -p$PROXY_PORT -a -n -i0.0.0.0 -e0.0.0.0
EOF
}

function write_users() {
    mkdir -p "$(dirname $USERFILE)"
    echo "$PROXY_USER:CL:$PROXY_PASS" > "$USERFILE"
}

function reload_3proxy() {
    systemctl daemon-reload
    systemctl restart 3proxy
    sleep 1
}

function make_service() {
    cat <<EOF > "$SYSTEMD_FILE"
[Unit]
Description=3proxy tiny proxy server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy $CONFIG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable 3proxy
}

function add_user() {
    read -p "Введите новый логин: " NEW_USER
    while [[ -z "$NEW_USER" ]]; do
        print_red "Логин не должен быть пустым!"
        read -p "Введите новый логин: " NEW_USER
    done
    read -s -p "Введите пароль для $NEW_USER: " NEW_PASS
    echo
    echo "$NEW_USER:CL:$NEW_PASS" >> "$USERFILE"
    print_green "Пользователь $NEW_USER добавлен!"
    write_config
    reload_3proxy
}

function del_user() {
    read -p "Введите логин для удаления: " DEL_USER
    if grep -q "^$DEL_USER:" "$USERFILE"; then
        grep -v "^$DEL_USER:" "$USERFILE" > "$USERFILE.tmp" && mv "$USERFILE.tmp" "$USERFILE"
        print_green "Пользователь $DEL_USER удалён!"
        write_config
        reload_3proxy
    else
        print_red "Такого пользователя нет!"
    fi
}

function list_users() {
    print_green "Список пользователей:"
    cut -d: -f1 "$USERFILE"
}

function show_menu() {
    echo
    print_green "=== Меню управления SOCKS5 ==="
    echo "1) Добавить пользователя"
    echo "2) Удалить пользователя"
    echo "3) Показать пользователей"
    echo "4) Перезапустить прокси"
    echo "5) Статус прокси"
    echo "6) Проверка UDP ASSOCIATE"
    echo "7) Выйти"
    echo
    read -p "Ваш выбор: " CHOICE
    case $CHOICE in
        1) add_user ;;
        2) del_user ;;
        3) list_users; pause ;;
        4) reload_3proxy; print_green "Прокси перезапущен."; pause ;;
        5) systemctl status 3proxy --no-pager; pause ;;
        6) udp_check; pause ;;
        7) exit 0 ;;
        *) print_red "Неверный выбор!";;
    esac
}

function udp_check() {
    print_green "Проверка поддержки UDP ASSOCIATE на SOCKS5 $PROXY_USER:$PROXY_PASS@127.0.0.1:$PROXY_PORT ..."
    python3 - <<EOF
import sys, socket, socks

server = '127.0.0.1'
port = int("$PROXY_PORT")
user = "$PROXY_USER"
password = "$PROXY_PASS"

try:
    sock = socks.socksocket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.set_proxy(socks.SOCKS5, server, port, True, user, password)
    sock.settimeout(5)
    sock.sendto(b'\x00'*16, ("8.8.8.8", 53))
    print(">>> \033[92mUDP ASSOCIATE через SOCKS5 прошёл успешно!\033[0m")
except Exception as e:
    print(">>> \033[91mUDP ASSOCIATE через SOCKS5 не работает: %s\033[0m" % e)
EOF
}

function first_install() {
    install_deps
    install_3proxy
    ask_creds
    write_users
    write_config
    make_service
    reload_3proxy
    print_green "Прокси успешно установлен и запущен!"
    cp "$0" /usr/local/bin/socks5mgr
    chmod +x /usr/local/bin/socks5mgr

    # Проверка UDP сразу после установки:
    udp_check

    print_green "Для управления прокси введите: sudo socks5mgr"
}

# === Запуск ===

if [[ ! -f "$CONFIG_FILE" || ! -f "$USERFILE" ]]; then
    print_green "Начальная установка SOCKS5-прокси с поддержкой UDP!"
    first_install
fi

while true; do
    show_menu
done
