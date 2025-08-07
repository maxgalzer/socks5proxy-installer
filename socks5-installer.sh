#!/bin/bash

set -e

# Функция логирования ошибок
log_error() {
    echo "[ERROR] $1" | tee -a /var/log/socks5_installer.log >&2
}

# Функция логирования инфо
log_info() {
    echo "[INFO] $1" | tee -a /var/log/socks5_installer.log
}

log_info "SOCKS5/UDP автоскрипт: старт установки"

if ! command -v apt &>/dev/null; then
    log_error "apt не найден! Требуется Ubuntu/Debian"
    exit 1
fi

# --- Сбор данных ---

read -rp "Введите порт для SOCKS5 (по умолчанию 1080): " SOCKS_PORT
SOCKS_PORT=${SOCKS_PORT:-1080}

read -rp "Введите основной логин для доступа: " SOCKS_USER
SOCKS_USER=${SOCKS_USER:-user}

read -rp "Введите пароль для $SOCKS_USER: " SOCKS_PASS
SOCKS_PASS=${SOCKS_PASS:-$(openssl rand -hex 8)}

# --- Установка Dante ---
log_info "Обновление системы и установка зависимостей..."
apt update -y && apt install -y dante-server whois

# --- Конфигурирование пользователей ---
PASSWD_FILE="/etc/sockd.passwd"
touch "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE"

add_user() {
    local user=$1
    local pass=$2
    if grep -q "^$user:" "$PASSWD_FILE"; then
        log_error "Пользователь $user уже существует."
        return 1
    fi
    echo "$user:$(mkpasswd -m sha-512 $pass)" >> "$PASSWD_FILE"
    log_info "Добавлен пользователь $user"
}

remove_user() {
    local user=$1
    if ! grep -q "^$user:" "$PASSWD_FILE"; then
        log_error "Пользователь $user не найден."
        return 1
    fi
    sed -i "/^$user:/d" "$PASSWD_FILE"
    log_info "Удалён пользователь $user"
}

# Добавление основного пользователя
add_user "$SOCKS_USER" "$SOCKS_PASS"

# --- Генерация конфига Dante ---
cat >/etc/danted.conf <<EOF
logoutput: /var/log/danted.log

internal: 0.0.0.0 port = $SOCKS_PORT
external: $(hostname -I | awk '{print $1}')

method: username none
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    method: username
    log: connect disconnect error
}
EOF

# --- PAM авторизация ---
cat >/etc/pam.d/sockd <<EOF
auth required pam_pwdfile.so pwdfile $PASSWD_FILE
account required pam_permit.so
EOF

# --- Обеспечим автозапуск и рестарт sockd ---
systemctl enable --now sockd

# --- Меню управления юзерами ---
manage_users() {
    while true; do
        echo "=== Управление пользователями ==="
        echo "1. Добавить пользователя"
        echo "2. Удалить пользователя"
        echo "3. Показать пользователей"
        echo "0. Продолжить"
        read -rp "Выбор: " a
        case $a in
            1)
                read -rp "Имя пользователя: " u
                read -rp "Пароль: " p
                add_user "$u" "$p"
                ;;
            2)
                read -rp "Имя пользователя: " u
                remove_user "$u"
                ;;
            3)
                cut -d: -f1 "$PASSWD_FILE"
                ;;
            0) break ;;
            *) echo "Неизвестная опция" ;;
        esac
    done
}

manage_users

# --- Перезапуск sockd ---
systemctl restart sockd

sleep 2

# --- Проверка работы (TCP и UDP) ---
log_info "Проверка TCP/UDP SOCKS5..."

TMP_LOG=/tmp/socks5_test.log
{
    python3 - <<EOF
import socket, socks
import sys
try:
    s = socks.socksocket()
    s.set_proxy(socks.SOCKS5, "127.0.0.1", $SOCKS_PORT, True, "$SOCKS_USER", "$SOCKS_PASS")
    s.settimeout(5)
    s.connect(("1.1.1.1", 53))
    s.sendall(b"\x00" * 4)
    s.close()
    print("SOCKS5 TCP/UDP OK")
except Exception as e:
    print("FAIL:", e)
    sys.exit(1)
EOF
} >"$TMP_LOG" 2>&1 || {
    log_error "Прокси не работает! Логи теста:"
    cat "$TMP_LOG"
    exit 1
}

log_info "Прокси успешно поднят!"

# --- Сбор домена или IP ---
PUBLIC_HOST=$(curl -s https://ipinfo.io/hostname || hostname -f)
if [[ -z "$PUBLIC_HOST" || "$PUBLIC_HOST" == "localhost" ]]; then
    PUBLIC_HOST=$(curl -s https://api.ipify.org)
fi

# --- Сбор ссылки для Telegram ---
TG_LINK="tg://socks?server=$PUBLIC_HOST&port=$SOCKS_PORT&user=$SOCKS_USER&pass=$SOCKS_PASS"
echo
echo "-----------"
echo "Ваша Telegram-ссылка:"
echo "$TG_LINK"
echo "-----------"

log_info "Инструкция: добавьте этот прокси в Telegram, чтобы пользоваться SOCKS5/UDP!"

exit 0
