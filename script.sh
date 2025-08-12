#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать с правами root или через sudo."
  exit 1
fi

read -p "Имя нового пользователя: " NEW_USER
read -s -p "Пароль нового пользователя: " NEW_USER_PASSWORD; echo
read -p "Новый SSH порт (например, 2222): " NEW_SSH_PORT
read -p "Вставьте публичный SSH-ключ для $NEW_USER: " SSH_PUBLIC_KEY
NEW_SSH_PORT=${NEW_SSH_PORT:-2222}

# Получаем IPv4-адрес сервера
# Пытаемся найти IP-адрес основного интерфейса (исключаем loopback)
SERVER_IP=$(ip -4 addr show | grep -v '127.0.0.1' | grep -oP 'inet \K[\d.]+' | head -n 1)
if [[ -z "$SERVER_IP" ]]; then
  echo "Не удалось определить IPv4-адрес сервера. Используйте <server-ip> в команде подключения."
  SERVER_IP="<server-ip>"
fi

# Создаем пользователя и меняем пароль
if id -u "$NEW_USER" &>/dev/null; then
  echo "Пользователь $NEW_USER уже существует, пропускаем создание."
else
  adduser --disabled-password --gecos "" "$NEW_USER"
  echo "$NEW_USER:$NEW_USER_PASSWORD" | chpasswd
  usermod -aG sudo "$NEW_USER"
fi

# Настраиваем SSH-ключ
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "$AUTH_KEYS"
chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

# Настраиваем sshd
SSHD_CONFIG="/etc/ssh/sshd_config"

# Заменяем или добавляем Port
if grep -q "^#Port 22" "$SSHD_CONFIG"; then
  sed -i "s/^#Port 22/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
elif grep -q "^Port " "$SSHD_CONFIG"; then
  sed -i "s/^Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
else
  echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
fi

# Отключаем PasswordAuthentication
if grep -q "^PasswordAuthentication yes" "$SSHD_CONFIG"; then
  sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/" "$SSHD_CONFIG"
elif ! grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
  echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
fi

# Отключаем root login
if grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
  sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" "$SSHD_CONFIG"
else
  echo "PermitRootLogin no" >> "$SSHD_CONFIG"
fi

# Настраиваем AllowUsers
if grep -q "^AllowUsers" "$SSHD_CONFIG"; then
  sed -i "s/^AllowUsers.*/AllowUsers $NEW_USER/" "$SSHD_CONFIG"
else
  echo "AllowUsers $NEW_USER" >> "$SSHD_CONFIG"
fi

# Устанавливаем fail2ban
apt-get update
apt-get install -y fail2ban

sudo apt install openssh-server -y

sudo systemctl enable ssh

sudo systemctl start ssh

# Перезапускаем sshd
if systemctl is-active sshd &>/dev/null; then
  systemctl restart sshd
else
  systemctl restart ssh
fi

# Настраиваем ufw
ufw allow "$NEW_SSH_PORT"/tcp
ufw deny 22/tcp
ufw default deny incoming
ufw --force enable

echo "Готово! Пользователь $NEW_USER создан, SSH-ключ настроен, sshd слушает на порту $NEW_SSH_PORT."
echo "SSH настроен: парольная аутентификация отключена, root-доступ запрещён, разрешён доступ только для $NEW_USER."
echo "Подключайтесь через: ssh -i ~/.ssh/<filename> -p $NEW_SSH_PORT $NEW_USER@$SERVER_IP"