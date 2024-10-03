#!/bin/bash

# Вихід, якщо виникла помилка
set -e

# Функція для відображення повідомлень
log() {
    echo "[INFO] $1"
}

error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Перевірка на root
if [ "$(id -u)" -ne 0 ]; then
    error_exit "Скрипт потребує прав root. Спробуйте запустити з sudo."
fi

# Завантаження необхідних модулів
for module in ip_nat_pptp pptp gre; do
    if ! lsmod | grep -q "^${module}"; then
        log "Завантаження модуля: $module"
        modprobe "$module" || error_exit "Не вдалося завантажити модуль $module"
    else
        log "Модуль $module вже завантажено."
    fi
done

# Визначення мережевого інтерфейсу
network_interface=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$network_interface" ]; then
    error_exit "Не вдалося визначити мережевий інтерфейс."
fi
log "Вибрано мережевий інтерфейс: $network_interface"

# Оновлення пакетів та встановлення pptpd
apt update -y || error_exit "Не вдалося оновити списки пакетів."
apt install -y pptpd iptables-persistent || error_exit "Не вдалося встановити необхідні пакети."

# Налаштування sysctl для ip_forward
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-pptpd.conf
sysctl -p /etc/sysctl.d/99-pptpd.conf || error_exit "Не вдалося налаштувати ip_forward."

# Налаштування iptables
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT
iptables -C INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 1723 -j ACCEPT
iptables -C INPUT --protocol 47 -j ACCEPT 2>/dev/null || iptables -I INPUT --protocol 47 -j ACCEPT
iptables -t nat -C POSTROUTING -s 192.168.2.0/24 -o "$network_interface" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.2.0/24 -o "$network_interface" -j MASQUERADE
iptables -C FORWARD -s 192.168.2.0/24 -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j TCPMSS --set-mss 1356 2>/dev/null || \
iptables -I FORWARD -s 192.168.2.0/24 -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j TCPMSS --set-mss 1356

# Збереження правил iptables
netfilter-persistent save || error_exit "Не вдалося зберегти правила iptables."

# Створення або оновлення /etc/rc.local через systemd
if ! systemctl list-unit-files | grep -q rc-local; then
    log "Створення системного сервісу rc-local."
    cat > /etc/systemd/system/rc-local.service <<EOF
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
RemainAfterExit=yes
GuessMainPID=no

[Install]
WantedBy=multi-user.target
EOF

    chmod +x /etc/rc.local

    systemctl enable rc-local
    systemctl start rc-local
fi

# Додавання правил до rc.local, якщо їх ще немає
if ! grep -q "iptables" /etc/rc.local; then
    sed -i '/^exit 0/d' /etc/rc.local

    cat >> /etc/rc.local <<END
# Налаштування iptables
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
iptables -I INPUT -p tcp --dport 1723 -j ACCEPT
iptables -I INPUT --protocol 47 -j ACCEPT
iptables -t nat -A POSTROUTING -s 192.168.2.0/24 -o $network_interface -j MASQUERADE
iptables -I FORWARD -s 192.168.2.0/24 -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j TCPMSS --set-mss 1356

exit 0
END

    log "Оновлено /etc/rc.local."
fi

# Перезапуск rc.local
systemctl restart rc-local || error_exit "Не вдалося перезапустити rc-local."

# Очищення екрану
clear

# Відображення заголовку
echo ""
echo " +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+ "
echo " |       PPTP VPN Setup Script            | "
echo " +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+ "
echo ""

# Введення логіну та паролю
read -p " [#] Введіть логін PPTP VPN: " NAME
while [[ -z "$NAME" ]]; do
    echo "Логін не може бути порожнім."
    read -p " [#] Введіть логін PPTP VPN: " NAME
done

read -s -p " [#] Введіть пароль PPTP VPN: " PASS
echo ""
while [[ -z "$PASS" ]]; do
    echo "Пароль не може бути порожнім."
    read -s -p " [#] Введіть пароль PPTP VPN: " PASS
    echo ""
done

# Додавання користувача до chap-secrets
cat >/etc/ppp/chap-secrets <<END
$NAME pptpd $PASS *
END

# Налаштування pptpd.conf
cat >/etc/pptpd.conf <<END
option /etc/ppp/options.pptpd
logwtmp
localip 192.168.2.1
remoteip 192.168.2.10-100
END

# Налаштування options.pptpd
cat >/etc/ppp/options.pptpd <<END
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns 8.8.8.8
ms-dns 8.8.4.4
proxyarp
lock
nobsdcomp 
novj
novjccomp
nologfd
END

# Встановлення wget, якщо необхідно
if ! command -v wget >/dev/null 2>&1; then
    log "Встановлення wget."
    apt install -y wget || error_exit "Не вдалося встановити wget."
fi

# Отримання зовнішньої IP-адреси
IP=$(wget -q -O - http://api.ipify.org)

# Відображення інформації
echo ""
echo " +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+ "
echo " |       PPTP VPN Setup Script            | "
echo " +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+ "
echo ""
if [ -n "$IP" ]; then
    echo " [#] Зовнішня IP-адреса: $IP"
else
    echo " [!] НЕ вдалося визначити зовнішню IP-адресу [!]"
fi
echo " [#] PPTP VPN Логін: $NAME"
echo " [#] PPTP VPN Пароль: $PASS"
echo ""
echo " +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+"
echo ""

sleep 3

# Перезапуск сервісу pptpd
systemctl restart pptpd || error_exit "Не вдалося перезапустити pptpd."

log "PPTP VPN успішно налаштовано."

exit 0
