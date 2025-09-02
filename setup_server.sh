#!/usr/bin/env bash
set -euo pipefail

########################################
# Helpers
########################################
log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[DONE]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

########################################
# Inputs
########################################
gather_inputs() {
  POSTGRES_PASSWORD="changeme_pg"
  CODE_SERVER_PASSWORD="changeme_code"
  PGADMIN_EMAIL="admin@example.com"
  SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  ok "Inputs set. (You can edit defaults in script if needed)"
}

########################################
# System prep
########################################
prepare_system() {
  log "Updating system and installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y dist-upgrade -qq
  apt-get install -y tmux nano zip unzip curl git ufw apt-transport-https ca-certificates gnupg lsb-release -qq
  ok "System ready."
}

########################################
# Python 3.10
########################################
install_python() {
  log "Installing Python 3.10..."
  apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip -qq
  update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
  update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3 1
  ok "Python 3.10 installed."
}

########################################
# PostgreSQL 14
########################################
install_postgres() {
  log "Installing PostgreSQL 14..."
  apt-get install -y postgresql-14 postgresql-client-14 postgresql-contrib -qq

  PG_CONF="/etc/postgresql/14/main/postgresql.conf"
  PG_HBA="/etc/postgresql/14/main/pg_hba.conf"

  sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
  sed -i "s/^#\?port.*/port = 5432/" "$PG_CONF"
  echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PG_HBA"

  systemctl enable --now postgresql

  PW_ESC=${POSTGRES_PASSWORD//\'/\'\'}
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE postgres WITH PASSWORD '${PW_ESC}';"

  ok "PostgreSQL 14 ready and accessible on 0.0.0.0:5432"
}

########################################
# code-server
########################################
install_codeserver() {
  log "Installing code-server..."
  curl -fsSL https://code-server.dev/install.sh | sh
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8443
auth: password
password: "${CODE_SERVER_PASSWORD}"
cert: false
EOF
  systemctl enable --now code-server
  ok "code-server running on :8443"
}

########################################
# Docker + NPM + Portainer
########################################
install_docker_stack() {
  log "Installing Docker & Compose..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
  systemctl enable --now docker

  mkdir -p /opt/stack
  cat > /opt/stack/docker-compose.yml <<'YAML'
version: "3.8"
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./npm-data:/data
      - ./letsencrypt:/etc/letsencrypt

  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer-data:/data
YAML

  cd /opt/stack
  docker compose up -d
  ok "NPM and Portainer running."
}

########################################
# Firewall
########################################
configure_ufw() {
  log "Configuring firewall..."
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 81/tcp
  ufw allow 443/tcp
  ufw allow 9443/tcp
  ufw allow 8443/tcp
  ufw allow 5432/tcp
  ufw --force enable
  ok "Firewall configured."
}

########################################
# Summary
########################################
print_summary() {
  echo -e "
================= نصب کامل شد =================
IP سرور شما: ${SERVER_IP}

[PostgreSQL 14]
- آدرس: postgresql://postgres:${POSTGRES_PASSWORD}@${SERVER_IP}:5432/postgres
- کاربر: postgres
- پورت: 5432

[code-server]
- URL: http://${SERVER_IP}:8443/
- کاربر: root
- پسورد: ${CODE_SERVER_PASSWORD}

[Nginx Proxy Manager]
- URL: http://${SERVER_IP}:81/
- پیش‌فرض: admin@example.com / changeme

[Portainer]
- URL: https://${SERVER_IP}:9443/

[ابزارها]
- نصب شده: tmux, nano, zip, unzip, curl, git, python3.10, pip3

فایل خلاصه: /root/setup_summary.txt
================================================
" | tee /root/setup_summary.txt
}

########################################
# MAIN
########################################
main() {
  need_root
  gather_inputs
  prepare_system
  install_python
  install_postgres
  install_codeserver
  install_docker_stack
  configure_ufw
  print_summary
}
main "$@"
