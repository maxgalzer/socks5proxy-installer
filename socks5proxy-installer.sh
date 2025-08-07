#!/bin/bash

# === SOCKS5 3proxy Installer by ChatGPT ===
# Ubuntu 20/22+ (root only!)

set -e

# === 1. Переменные ===
read -p "Введите порт для SOCKS5 (например, 1080): " PORT
read -p "Введите логин: " LOGIN
read -s -p "Введите пароль: " PASS; echo

# === 2. Подготовка окружения ===
apt update
apt install -y build-essential wget git

# === 3. Скачиваем и компилируем 3proxy ===
if [ -d "/tmp/3proxy" ]; then rm -rf /tmp/3proxy; fi
cd /tmp
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
make -f Makefile.Linux
cp ./src/3proxy /usr/local/bin/
mkdir -p /etc/3proxy/logs

# === 4. Создаём конфиг ===
cat >/etc/3proxy/3proxy.cfg <<EOF
daemon
nserver 8.8.8.8
nserver 1.1.1.1
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /etc/3proxy/logs/3proxy.log D
users $LOGIN:CL:$PASS
auth strong
allow
socks -p$PORT -a -n -i0.0.0.0 -e0.0.0.0
EOF

chown -R nobody:nogroup /etc/3proxy/logs

# === 5. Создаём systemd unit ===
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy tiny proxy server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

sleep 1

# === 6. Firewall (UFW) ===
if command -v ufw &> /dev/null; then
    ufw allow $PORT/tcp || true
    ufw reload || true
fi

# === 7. Показываем статус и tg:// ссылку ===
EXT_IP=$(curl -s https://api.ipify.org)
TG_LINK="tg://socks?server=$EXT_IP&port=$PORT&user=$LOGIN&pass=$PASS"

echo
echo "=============================="
echo "   SOCKS5 proxy установлен!   "
echo "=============================="
echo "IP:        $EXT_IP"
echo "Порт:      $PORT"
echo "Логин:     $LOGIN"
echo "Пароль:    $PASS"
echo "----------------------------------"
echo "Telegram ссылка:"
echo "$TG_LINK"
echo "----------------------------------"
echo "Для проверки: curl -x socks5h://$LOGIN:$PASS@$EXT_IP:$PORT https://api.ipify.org"
echo "----------------------------------"
echo "Для удаления: systemctl stop 3proxy && systemctl disable 3proxy && rm -rf /etc/3proxy /etc/systemd/system/3proxy.service /usr/local/bin/3proxy"
echo "----------------------------------"
echo "Статус сервиса:"
systemctl status 3proxy --no-pager | head -20

exit 0
