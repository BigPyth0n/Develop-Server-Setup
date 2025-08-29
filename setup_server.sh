#!/usr/bin/env bash
set -euo pipefail

########################################
#      Helpers: prompts & printing
########################################
log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[DONE]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

need_root(){ [[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

prompt_value() { # $1=question  $2=default -> echo result
  local q="$1" def="${2-}" ans=""
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$q: " ans || true
    while [[ -z "$ans" ]]; do read -r -p "$q (خالی نباشد): " ans || true; done
  fi
  echo "$ans"
}

prompt_secret() { # $1=question -> echo result (confirm twice)
  local q="$1" a1="" a2=""
  while true; do
    read -r -s -p "$q (مخفی): " a1 || true; echo
    [[ -n "$a1" ]] || { echo " - نمی‌تواند خالی باشد."; continue; }
    read -r -s -p "تکرار $q: " a2 || true; echo
    if [[ "$a1" == "$a2" ]]; then
      echo "$a1"
      return 0
    else
      echo " - مطابقت ندارند؛ دوباره تلاش کن."
    fi
  done
}

write_summary() { # $1=text
  local f="/root/setup_summary.txt"
  umask 077
  printf "%s\n" "$1" > "$f"
  chmod 600 "$f"
  echo
  echo "📄 خلاصهٔ نصب در: $f (فقط root دسترسی دارد)"
}

########################################
#      0) Collect interactive inputs
########################################
gather_inputs() {
  echo "=== پیکربندی تعاملی نصب ==="

  TIMEZONE=$(prompt_value "Timezone" "Etc/UTC")

  # PostgreSQL (local)
  POSTGRES_PORT=$(prompt_value "پورت PostgreSQL (لوکال)" "5432")
  POSTGRES_USER=$(prompt_value "نام کاربری PostgreSQL" "postgres")
  POSTGRES_PASSWORD=$(prompt_secret "پسورد PostgreSQL")
  POSTGRES_DB=$(prompt_value "نام دیتابیس پیش‌فرض" "appdb")

  # Metabase metadata DB (on Postgres local)
  MB_DB_NAME=$(prompt_value "نام دیتابیس متابیس (metadata)" "metabase")
  MB_DB_USER=$(prompt_value "یوزر دیتابیس متابیس" "metabase")
  MB_DB_PASSWORD=$(prompt_secret "پسورد دیتابیس متابیس")

  # pgAdmin (local)
  PGADMIN_PORT=$(prompt_value "پورت pgAdmin (لوکال)" "5050")
  PGADMIN_EMAIL=$(prompt_value "ایمیل ادمین pgAdmin" "admin@example.com")
  PGADMIN_PASSWORD=$(prompt_secret "پسورد حساب pgAdmin (برای اولین ورود)")

  # code-server (local)
  CODE_SERVER_PORT=$(prompt_value "پورت code-server (لوکال)" "8443")
  CODE_SERVER_PASSWORD=$(prompt_secret "پسورد ورود code-server")

  # NPM/Portainer are public on standard ports; domains are configured later in NPM UI.
  echo
  echo "✅ ورودی‌ها دریافت شد."
}

########################################
#      1) System & basics & Python 3.11
########################################
update_upgrade() {
  log "Updating & upgrading system..."
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

install_python_311() {
  log "Installing Python 3.11 and setting default..."
  add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
  apt-get update -qq
  apt-get install -y python3.11 python3.11-venv python3.11-dev python3.11-distutils -qq > /dev/null
  if [[ ! -x /usr/bin/pip3.11 ]]; then
    /usr/bin/python3.11 -m ensurepip --upgrade || true
    command -v pip3.11 >/dev/null 2>&1 && ln -sf "$(command -v pip3.11)" /usr/bin/pip3.11 || apt-get install -y python3-pip -qq || true
  fi
  update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
  [[ -x /usr/bin/pip3.11 ]] && update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.11 1 || true
  ok "Python 3.11 ready."
}

########################################
#      2) PostgreSQL (local-only)
########################################
install_postgresql_local() {
  log "Installing PostgreSQL (local-only)..."
  apt-get install -y postgresql postgresql-contrib -qq
  PG_VER="$(psql -V | awk '{print $3}' | cut -d. -f1,2 || true)"
  [[ -z "$PG_VER" ]] && PG_VER="14"
  local CONF_DIR="/etc/postgresql/${PG_VER}/main"

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

  # Metabase metadata DB/user
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${MB_DB_USER}'" | grep -q 1 \
    || sudo -u postgres psql -c "CREATE ROLE ${MB_DB_USER} LOGIN PASSWORD '${MB_DB_PASSWORD}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${MB_DB_NAME}'" | grep -q 1 \
    || sudo -u postgres createdb -O "${MB_DB_USER}" "${MB_DB_NAME}"

  ok "PostgreSQL bound to 127.0.0.1:${POSTGRES_PORT}."
}

########################################
#      3) pgAdmin (local standalone)
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

  # راه‌اندازی سرویس وب pgAdmin
  if [[ -x /usr/pgadmin4/bin/setup-web.sh ]]; then
    /usr/pgadmin4/bin/setup-web.sh --yes --mode server
  fi
  systemctl enable --now pgadmin4 || systemctl restart pgadmin4
  ok "pgAdmin is listening on 127.0.0.1:${PGADMIN_PORT}"
  echo "یادداشت: در اولین ورود به UI، یک حساب با ایمیل/پسوردی که همین‌جا وارد کردی بساز."
}

########################################
#      4) code-server (local, root)
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
  ok "code-server running on 127.0.0.1:${CODE_SERVER_PORT}"
}

########################################
#      5) Docker & Compose
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
  ok "Docker ready."
}

########################################
#      6) UFW (SSH/Web only)
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
  # 5432 و 5050 عمداً باز نیستند (لوکال/پشت NPM)
  ufw --force enable
  ok "UFW configured."
}

########################################
#      7) Compose stack (pg-gw, Metabase, NPM, Portainer)
########################################
write_stack() {
  log "Writing Docker stack..."
  mkdir -p /opt/stack/{metabase,npm,portainer}
  cat > /opt/stack/.env <<EOF
TIMEZONE=${TIMEZONE}
MB_DB_NAME=${MB_DB_NAME}
MB_DB_USER=${MB_DB_USER}
MB_DB_PASSWORD=${MB_DB_PASSWORD}
EOF

  cat > /opt/stack/docker-compose.yml <<'YAML'
name: webstack
services:
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

  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
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

  ok "Docker compose written."
}

bring_up_stack() {
  log "Starting Docker stack..."
  cd /opt/stack
  docker compose pull
  docker compose up -d
  ok "Stack is up."
}

########################################
#      8) Final Summary
########################################
print_summary() {
  local SUM="
==================== خلاصهٔ نصب ====================
[عمومی/وب]
- Nginx Proxy Manager (Admin):  http://YOUR_SERVER_IP:81  (SSL از طریق NPM برای سرویس‌ها بگیر)
- Portainer:                    https://YOUR_SERVER_IP:9443

[لوکال]
- PostgreSQL: 127.0.0.1:${POSTGRES_PORT}
  - User: ${POSTGRES_USER}
  - Password: ${POSTGRES_PASSWORD}
  - Default DB: ${POSTGRES_DB}

- Metabase (از طریق NPM منتشر کن)
  - Metadata DB → ${MB_DB_NAME} @ postgres (از طریق pg-gateway)

- pgAdmin (لوکال، پشت NPM منتشر کن)
  - Bind: 127.0.0.1:${PGADMIN_PORT}
  - First login (خودت ایجاد می‌کنی): ${PGADMIN_EMAIL} / ${PGADMIN_PASSWORD}

- code-server (لوکال)
  - URL:  http://127.0.0.1:${CODE_SERVER_PORT}
  - Password: ${CODE_SERVER_PASSWORD}

[Firewall/UFW]
- باز: 22(SSH), 80, 81, 443, 9443
- بسته: 5432 (Postgres), ${PGADMIN_PORT} (pgAdmin), ${CODE_SERVER_PORT} (code-server)

[گام‌های بعدی در NPM]
- ساخت Proxy Host برای pgAdmin:
  - Domain: pgadmin.yourdomain.com
  - Forward Host/IP: 127.0.0.1
  - Forward Port: ${PGADMIN_PORT}
  - SSL: Let’s Encrypt + Force SSL + HTTP/2

- ساخت Proxy Host برای Metabase:
  - Domain: metabase.yourdomain.com
  - Forward Host/IP: metabase
  - Forward Port: 3000
  - SSL: Let’s Encrypt + Force SSL + HTTP/2
===================================================
"
  echo "$SUM"
  write_summary "$SUM"
}

########################################
#                  MAIN
########################################
main() {
  need_root
  gather_inputs
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
  print_summary
}

main "$@"
