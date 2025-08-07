#!/bin/bash

set -e

# Цвета для красоты
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "${CYAN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

# Проверка платформы
if ! command -v apt &>/dev/null; then
    error "apt не найден! Требуется Ubuntu/Debian"
    exit 1
fi

# --- Сбор данных ---
echo -e "${CYAN}=== Установка SOCKS5/UDP-прокси с управлением пользователями ===${NC}"

read -rp "Порт для SOCKS5 (по умолчанию 1080): " SOCKS_PORT
SOCKS_PORT=${SOCKS_PORT:-1080}

read -rp "Основной логин: " SOCKS_USER
SOCKS_USER=${SOCKS_USER:-user}

read -rp "Пароль для $SOCKS_USER (Enter — сгенерировать): " SOCKS_PASS
SOCKS_PASS=${SOCKS_PASS:-$(openssl rand -hex 8)}

PASSWD_FILE="/etc/sockd.passwd"
DANTED_CONF="/etc/danted.conf"
LOG_FILE="/var/log/danted.log"

# --- Установка Dante ---
log "Обновление системы и установка Dante..."
apt update -y && apt install -y dante-server whois python3 python3-pip

# --- Установка PAM-модуля ---
if ! [ -f /lib/security/pam_pwdfile.so ]; then
    log "Установка pam_pwdfile.so..."
    apt install -y libpam-pwdfile
fi

touch "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE"

# --- Генерация пользователей (хэш SHA-512) ---
add_user() {
    local user=$1
    local pass=$2
    if grep -q "^$user:" "$PASSWD_FILE"; then
        error "Пользователь $user уже существует."
        return 1
    fi
    echo "$user:$(mkpasswd -m sha-512 $pass)" >> "$PASSWD_FILE"
    success "Добавлен пользователь $user"
}

remove_user() {
    local user=$1
    if ! grep -q "^$user:" "$PASSWD_FILE"; then
        error "Пользователь $user не найден."
        return 1
    fi
    sed -i "/^$user:/d" "$PASSWD_FILE"
    success "Удалён пользователь $user"
}

list_users() {
    echo "Текущие пользователи:"
    cut -d: -f1 "$PASSWD_FILE"
}

random_creds() {
    u="user$(openssl rand -hex 3)"
    p="$(openssl rand -hex 8)"
    echo "$u $p"
}

# Добавление основного пользователя
add_user "$SOCKS_USER" "$SOCKS_PASS"

# --- Генерация danted.conf ---
cat >"$DANTED_CONF" <<EOF
logoutput: $LOG_FILE

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
cat > /etc/pam.d/sockd <<EOF
auth required pam_pwdfile.so pwdfile $PASSWD_FILE
account required pam_permit.so
EOF

# --- systemd, рестарт ---
systemctl enable --now sockd
sleep 1

# --- Меню управления пользователями ---
while true; do
    echo -e "\n${CYAN}=== Управление пользователями SOCKS5 ===${NC}"
    echo "1. Добавить пользователя"
    echo "2. Удалить пользователя"
    echo "3. Показать всех пользователей"
    echo "4. Сгенерировать случайные логин+пароль"
    echo "0. Продолжить установку"
    read -rp "Выберите действие: " action
    case $action in
        1)
            read -rp "Имя пользователя: " u
            read -rp "Пароль (Enter — сгенерировать): " p
            p=${p:-$(openssl rand -hex 8)}
            add_user "$u" "$p"
            ;;
        2)
            read -rp "Имя пользователя: " u
            remove_user "$u"
            ;;
        3)
            list_users
            ;;
        4)
            creds=($(random_creds))
            add_user "${creds[0]}" "${creds[1]}"
            echo "Сгенерировано: ${creds[0]} : ${creds[1]}"
            ;;
        0) break ;;
        *) echo "Неизвестная опция" ;;
    esac
done

systemctl restart sockd
sleep 2

# --- Проверка работы (TCP/UDP) ---
echo -e "\n${CYAN}Проверка работоспособности прокси...${NC}"

python3 - <<EOF
import socks, sys
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

# --- Информация о сервере и прокси ---
PUBLIC_IP=$(curl -s https://api.ipify.org)
HOST=$(curl -s https://ipinfo.io/hostname 2>/dev/null || hostname -f)
[[ -z "$HOST" || "$HOST" == "localhost" ]] && HOST="$PUBLIC_IP"

echo -e "\n${GREEN}=== Информация о вашем SOCKS5/UDP-прокси ===${NC}"
echo -e "${CYAN}Адрес (host):${NC}   $HOST"
echo -e "${CYAN}Порт:${NC}           $SOCKS_PORT"
echo -e "${CYAN}Пользователи:${NC}"
cut -d: -f1 "$PASSWD_FILE" | sed 's/^/    - /'
echo -e "${CYAN}Файл паролей:${NC}   $PASSWD_FILE"
echo -e "${CYAN}Конфиг:${NC}         $DANTED_CONF"
echo -e "${CYAN}Лог-файл:${NC}       $LOG_FILE"
echo -e "${CYAN}Статус сервиса:${NC} "
systemctl status sockd --no-pager -l | grep -E 'Active:|Loaded:|Listen'

echo -e "\n${CYAN}Telegram-ссылка для быстрого подключения:${NC}"
echo -e "tg://socks?server=$HOST&port=$SOCKS_PORT&user=$SOCKS_USER&pass=$SOCKS_PASS"

echo -e "\n${CYAN}Памятка:${NC}"
echo "— Добавьте прокси в Telegram через эту ссылку"
echo "— Можно использовать прокси в других приложениях (SOCKS5 + UDP)"
echo "— Для новых юзеров/паролей просто перезапустите скрипт"
echo "— Логи ошибок: $LOG_FILE"
echo "— Управление: systemctl restart|status|stop sockd"
echo
success "Установка завершена!"

exit 0
