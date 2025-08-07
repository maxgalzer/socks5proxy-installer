#!/usr/bin/env bash
set -e

LOGFILE="/var/log/socks5_installer.log"
touch "$LOGFILE"

function log() { echo -e "$1" | tee -a "$LOGFILE"; }
function die() { log "\033[0;31m[ОШИБКА]\033[0m $1"; exit 1; }
function ok()  { log "\033[0;32m[ОК]\033[0m $1"; }

log "===== SOCKS5 Proxy Install Start: $(date) ====="

# 1. Проверки
[[ $EUID -ne 0 ]] && die "Скрипт запускается только от root (sudo -i)!"

if ! command -v 3proxy >/dev/null 2>&1; then
  log "[Инфо] 3proxy не найден. Начинаю установку."
  apt update && apt install -y build-essential wget curl make gcc libpam0g-dev git python3-pip || die "apt install завершился с ошибкой!"
  cd /tmp
  rm -rf 3proxy
  git clone --depth=1 https://github.com/z3APA3A/3proxy.git || die "Не удалось клонировать репозиторий 3proxy"
  cd 3proxy
  make -f Makefile.Linux || die "Не удалось скомпилировать 3proxy"
  mkdir -p /usr/local/3proxy/bin
  if [[ -f bin/3proxy ]]; then
    cp bin/3proxy /usr/local/3proxy/bin/ || die "Не удалось скопировать бинарник 3proxy"
  elif [[ -f src/3proxy ]]; then
    cp src/3proxy /usr/local/3proxy/bin/ || die "Не удалось скопировать бинарник 3proxy"
  else
    die "Не найден собранный бинарник 3proxy (bin/3proxy или src/3proxy)"
  fi
  ln -sf /usr/local/3proxy/bin/3proxy /usr/bin/3proxy
  ok "3proxy установлен"
fi

# 2. Запрос параметров
read -p "Введите порт SOCKS5 [32126]: " PORT; PORT=${PORT:-32126}
read -p "Введите логин (латиница/цифры) [user]: " LOGIN; LOGIN=${LOGIN:-user}
read -sp "Введите пароль: " PASSWORD; echo
[[ -z "$PASSWORD" ]] && die "Пароль не может быть пустым!"

# 3. Генерация файла пользователей (plain-text)
USERS_FILE="/usr/local/3proxy/socks5.users"
mkdir -p /usr/local/3proxy
if [[ ! -f "$USERS_FILE" ]]; then
  echo "${LOGIN}:CL:${PASSWORD}" > "$USERS_FILE"
else
  grep -q "^$LOGIN:" "$USERS_FILE" && die "Пользователь $LOGIN уже существует! Удалите его перед повторной установкой или выберите другой логин."
  echo "${LOGIN}:CL:${PASSWORD}" >> "$USERS_FILE"
fi

# 4. Генерация конфига (plain-text users)
CONF="/usr/local/3proxy/socks5.conf"
USERS_LINE="users $(cat "$USERS_FILE" | paste -sd, -)"
cat > "$CONF" <<EOF
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
daemon
log /var/log/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N %p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
$USERS_LINE
allow *
proxy -n -a -p${PORT} -i0.0.0.0 -e0.0.0.0 -6
socks -n -a -p${PORT} -i0.0.0.0 -e0.0.0.0 -6
flush
EOF

ok "Конфиг создан: $CONF"

# 5. Systemd unit
SERVICE="/etc/systemd/system/3proxy-socks5.service"
cat > "$SERVICE" <<EOF
[Unit]
Description=3proxy SOCKS5 proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/3proxy $CONF
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now 3proxy-socks5 || die "Не удалось запустить 3proxy как systemd unit"

sleep 2

# 6. Firewall
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${PORT}/tcp || log "[warn] Не удалось открыть порт $PORT/tcp в ufw"
  ufw allow ${PORT}/udp || log "[warn] Не удалось открыть порт $PORT/udp в ufw"
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=${PORT}/tcp
  firewall-cmd --permanent --add-port=${PORT}/udp
  firewall-cmd --reload
fi

# 7. Управление пользователями
manage_users() {
  while true; do
    echo "====== Управление пользователями ======"
    echo "1. Добавить пользователя"
    echo "2. Удалить пользователя"
    echo "3. Показать пользователей"
    echo "0. Продолжить"
    read -p "Выберите действие: " CH
    case $CH in
      1)
        read -p "Новый логин: " NEWLOGIN
        grep -q "^$NEWLOGIN:" "$USERS_FILE" && { log "Пользователь уже есть"; continue; }
        read -sp "Новый пароль: " NEWPASS; echo
        echo "${NEWLOGIN}:CL:${NEWPASS}" >> "$USERS_FILE"
        USERS_LINE="users $(cat "$USERS_FILE" | paste -sd, -)"
        sed -i "/^users /c\\$USERS_LINE" "$CONF"
        systemctl restart 3proxy-socks5
        ok "Добавлен $NEWLOGIN"
        ;;
      2)
        read -p "Логин для удаления: " DELL
        grep -q "^$DELL:" "$USERS_FILE" || { log "Нет такого"; continue; }
        sed -i "/^$DELL:/d" "$USERS_FILE"
        USERS_LINE="users $(cat "$USERS_FILE" | paste -sd, -)"
        sed -i "/^users /c\\$USERS_LINE" "$CONF"
        systemctl restart 3proxy-socks5
        ok "Удалён $DELL"
        ;;
      3)
        log "Пользователи:\n$(cut -d: -f1 "$USERS_FILE")"
        ;;
      0) break;;
      *) echo "?" ;;
    esac
  done
}

manage_users

# 8. Получить внешний IP
EXT_IP=$(curl -s ipv4.icanhazip.com || curl -s ipinfo.io/ip || echo "server_ip")
[[ "$EXT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Ошибка получения внешнего IP ($EXT_IP)"

# 9. Проверка TCP
log "[Тест TCP] Проверяю работу SOCKS5 на TCP..."
curl --socks5 $LOGIN:$PASSWORD@$EXT_IP:$PORT https://api.ipify.org --max-time 15 || log "[Ошибка] TCP SOCKS5 не отвечает или заблокирован."

# 10. Проверка UDP (python3-pip нужен только для первой установки)
pip3 install --quiet --disable-pip-version-check PySocks || true
log "[Тест UDP] Проверяю работу UDP через socks (python test)..."
python3 - <<END || log "[Ошибка] Не удалось проверить UDP SOCKS5"
import socket, socks
try:
    s = socks.socksocket(socket.AF_INET, socket.SOCK_DGRAM)
    s.set_proxy(socks.SOCKS5, "$EXT_IP", $PORT, True, "$LOGIN", "$PASSWORD")
    s.sendto(b'test', ("1.1.1.1", 53))
    print("[ОК] UDP-трафик через SOCKS5 отправлен (на 100% работоспособность гарантии нет, смотри логи).")
except Exception as e:
    print("[ОШИБКА] UDP через SOCKS5 не работает: ", e)
END

# 11. Выдать tg:// ссылку
log "=========="
log "Ссылка для Telegram:"
log "tg://socks?server=$EXT_IP&port=$PORT&user=$LOGIN&pass=$PASSWORD"
log "=========="
ok "Готово! Логи: $LOGFILE"

exit 0
