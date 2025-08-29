#!/usr/bin/env bash
set -euo pipefail

########################################
#               CONFIG
########################################
TIMEZONE="${TIMEZONE:-Etc/UTC}"

# Postgres (لوکال)
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-CHANGE_ME_StrongPostgresPass!}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Metabase (متادیتا روی Postgres لوکال)
MB_DB_NAME="${MB_DB_NAME:-metabase}"
MB_DB_USER="${MB_DB_USER:-metabase}"
MB_DB_PASSWORD="${MB_DB_PASSWORD:-CHANGE_ME_MetabaseDBPass!}"

# pgAdmin (لوکال)
PGADMIN_EMAIL="${PGADMIN_EMAIL:-admin@example.com}"
PGADMIN_PASSWORD="${PGADMIN_PASSWORD:-CHANGE_ME_PgAdminPass!}"
PGADMIN_PORT="${PGADMIN_PORT:-5050}"

# code-server (لوکال/روت)
CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-CHANGE_ME_CodeServerPass!}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8443}"

log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[DONE]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

########################################
#   Update & Basics
########################################
update_upgrade() {
  log "Updating/Upgrading system..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y dist-upgrade -qq
  apt-get -y autoremove -qq
  timedatectl set-timezone "$TIMEZONE" || true
  ok "System updated."
}

install_basics() {
  log "Installing base packages..."
  apt-get install -y apt-transport-https ca-certificates curl gnupg unzip git nano zip ufw \
                     software-properties-common lsb-release -qq
  ok "Base packages installed."
}

########################################
#   Python 3.11 (default) — طبق خواستهٔ شما
########################################
install_python_311() {
  log "Installing Python 3.11..."
  add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
  apt-get update -qq
  apt-get install -y python3.11 python3.11-venv python3.11-dev python3.11-distutils -qq > /dev/null
  if [[ ! -x /usr/bin/pip3.11 ]]; then
    /usr/bin/python3.11 -m ensurepip --upgrade || true
    if command -v pip3.11 >/dev/null 2>&1; then
      ln -sf "$(command -v pip3.11)" /usr/bin/pip3.11 || true
    else
      apt-get install -y python3-pip -qq || true
    fi
  fi
  [[ -x /usr/bin/python3.11 ]] && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
  [[ -x /usr/bin/pip3.11    ]] && update-alternatives --install /usr/bin/pip3  pip3  /usr/bin/pip3.11    1
  ok "Python 3.11 installed and set as default."
}

########################################
#   PostgreSQL (لوکال)
########################################
install_postgresql_local() {
  log "Installing PostgreSQL (local-only)..."
  apt-get install -y postgresql postgresql-contrib -qq
  PG_VER="$(psql -V | awk '{print $3}' | cut -d. -f1,2 || true)"
  [[ -z "$PG_VER" ]] && PG_VER="14"
  CONF_DIR="/etc/postgresql/${PG_VER}/main"

  sed -i "s/^#\?listen_addresses.*/listen_addresses = '127.0.0.1'/" "${CONF_DIR}/postgresql.conf" || true
  sed -i "s/^#\?port.*/port = ${POSTGRES_PORT}/" "${CONF_DIR}/postgresql.conf" || true
  if ! grep -q "127.0.0.1/32" "${CONF_DIR}/pg_hba.conf"; then
    echo "host    all             all             127.0.0.1/32            md5" >> "${CONF_DIR}/pg_hba.conf"
  fi

  systemctl enable --now postgresql

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" | grep -q 1 \
    || sudo -u postgres psql -c "CREATE ROLE ${POSTGRES_USER} LOGIN PASSWORD '${POSTGRES_PASSWORD}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" | grep -q 1 \
    || sudo -u postgres createdb -O "${POSTGRES_USER}" "${POSTGRES_DB}"

  # DB و یوزر متابیس
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${MB_DB_USER}'" | grep -q 1 \
    || sudo -u postgres psql -c "CREATE ROLE ${MB_DB_USER} LOGIN PASSWORD '${MB_DB_PASSWORD}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${MB_DB_NAME}'" | grep -q 1 \
    || sudo -u postgres createdb -O "${MB_DB_USER}" "${MB_DB_NAME}"

  ok "PostgreSQL installed and bound to 127.0.0.1:${POSTGRES_PORT}."
}

########################################
#   pgAdmin (لوکال، standalone)
########################################
install_pgadmin_local() {
  log "Installing pgAdmin 4 (local standalone on 127.0.0.1:${PGADMIN_PORT})..."
  curl -fsS https://www.pgadmin.org/static/packages_pgadmin_org.pub | gpg --dearmor -o /usr/share/keyrings/pgadmin-keyring.gpg
  . /etc/os-release
  echo "deb [signed-by=/usr/share/keyrings/pgadmin-keyring.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/${UBUNTU_CODENAME} pgadmin4 main" \
    > /etc/apt/sources.list.d/pgadmin4.list
  apt-get update -qq
  apt-get install -y pgadmin4 -qq

  mkdir -p /etc/pgadmin
  cat >/etc/pgadmin/config_local.py <<EOF
DEFAULT_SERVER = '127.0.0.1'
DEFAULT_SERVER_PORT = ${PGADMIN_PORT}
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
ENHANCED_COOKIE_PROTECTION = True
EOF

  # ستاپ اولیه در صورت نیاز
  if [[ -x /usr/pgadmin4/bin/setup-web.sh ]]; then
    /usr/pgadmin4/bin/setup-web.sh --yes --mode server
  fi

  systemctl enable --now pgadmin4 || systemctl restart pgadmin4
  ok "pgAdmin is listening on 127.0.0.1:${PGADMIN_PORT}."
  echo
  echo "[NOTE] اولین ورود را از طریق UI pgAdmin انجام می‌دهی و اکانت می‌سازی."
  echo "      بعد از پابلیش پشت NPM، با HTTPS از اینترنت وارد می‌شی."
}

########################################
#   code-server (لوکال/روت)
########################################
install_codeserver_local() {
  log "Installing code-server (root, local-only)..."
  curl -fsSL https://code-server.dev/install.sh | sh
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 127.0.0.1:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF
  cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server (root)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:${CODE_SERVER_PORT} --auth password
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now code-server
  ok "code-server running on 127.0.0.1:${CODE_SERVER_PORT} (local)."
}

########################################
#   Docker & Compose
########################################
install_docker() {
  log "Installing Docker Engine & Compose plugin..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
  systemctl enable --now docker
  ok "Docker installed."
}

########################################
#   UFW (فقط وب/SSH)
########################################
configure_ufw() {
  log "Configuring UFW..."
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 81/tcp     # NPM Admin
  ufw allow 9443/tcp   # Portainer
  # 5432 و 5050 عمداً باز نمی‌شوند (لوکال/پشت NPM)
  ufw --force enable
  ok "UFW configured."
}

########################################
#   Docker Stack: pg-gateway + Metabase + NPM + Portainer
########################################
write_stack() {
  log "Writing Docker stack..."
  mkdir -p /opt/stack/{pg-gateway,metabase,npm,portainer}
  cat > /opt/stack/.env <<EOF
TIMEZONE=${TIMEZONE}

POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_PORT=${POSTGRES_PORT}

MB_DB_NAME=${MB_DB_NAME}
MB_DB_USER=${MB_DB_USER}
MB_DB_PASSWORD=${MB_DB_PASSWORD}
EOF

  cat > /opt/stack/docker-compose.yml <<'YAML'
name: webstack
services:
  # پل شبکه‌ای از کانتینرها به Postgres لوکال روی هاست
  pg-gateway:
    image: alpine/socat:latest
    command: ["tcp-listen:5432,fork,reuseaddr","tcp-connect:host.docker.internal:5432"]
    restart: unless-stopped
    networks: [ backend ]
    extra_hosts:
      - "host.docker.internal:host-gateway"

  metabase:
    image: metabase/metabase:latest
    restart: unless-stopped
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: ${MB_DB_NAME}
      MB_DB_PORT: 5432
      MB_DB_USER: ${MB_DB_USER}
      MB_DB_PASS: ${MB_DB_PASSWORD}
      MB_DB_HOST: pg-gateway
      TZ: ${TIMEZONE}
    depends_on: [ pg-gateway ]
    networks: [ backend ]
    # از طریق NPM منتشر کن (نیازی به ports مستقیم نیست)

  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"     # Public HTTP
      - "81:81"     # Admin UI
      - "443:443"   # Public HTTPS
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    networks: [ backend ]

  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer/data:/data
    networks: [ backend ]

networks:
  backend:
    driver: bridge
YAML

  ok "Docker compose written to /opt/stack/docker-compose.yml"
}

bring_up_stack() {
  log "Starting Docker stack..."
  cd /opt/stack
  docker compose pull
  docker compose up -d
  ok "Stack is up."
}

########################################
#   MAIN
########################################
main() {
  need_root
  update_upgrade
  install_basics
  install_python_311
  install_postgresql_local
  install_pgadmin_local
  install_codeserver_local
  install_docker
  configure_ufw
  write_stack
  bring_up_stack

  echo
  echo "==================== NEXT STEPS ===================="
  echo "- NPM Admin:           http://YOUR_SERVER_IP:81  (لاگین اولیه پیشفرض NPM را تغییر بده)"
  echo "- Portainer:           https://YOUR_SERVER_IP:9443"
  echo "- پابلیش pgAdmin پشت NPM:"
  echo "    Proxy Host → Domain: pgadmin.yourdomain.com"
  echo "    Forward Host/IP: 127.0.0.1   |  Forward Port: ${PGADMIN_PORT}"
  echo "    SSL: درخواست Let’s Encrypt + Force SSL + HTTP/2"
  echo "- پابلیش Metabase پشت NPM:"
  echo "    Domain: metabase.yourdomain.com"
  echo "    Forward Host/IP: metabase     |  Forward Port: 3000"
  echo "- اتصال pgAdmin به Postgres (داخل UI pgAdmin):"
  echo "    Host: 127.0.0.1   Port: ${POSTGRES_PORT}"
  echo "    Username: ${POSTGRES_USER}   Database: ${POSTGRES_DB}"
  echo "- Postgres همچنان از اینترنت بسته است (امن)."
  echo "- code-server فعلاً لوکال است (127.0.0.1:${CODE_SERVER_PORT})؛ اگر خواستی از بیرون، پشت NPM منتشرش کن."
  echo "===================================================="
}

main "$@"
