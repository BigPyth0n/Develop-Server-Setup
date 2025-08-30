#!/usr/bin/env bash
set -euo pipefail

########################################
# Helpers
########################################
log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[DONE]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

prompt_value() { # $1=question  $2=default
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

prompt_secret() { # $1=question
  local q="$1" a1="" a2=""
  while true; do
    read -r -s -p "$q (مخفی): " a1 || true; echo
    [[ -n "$a1" ]] || { echo " - نمی‌تواند خالی باشد."; continue; }
    read -r -s -p "تکرار $q: " a2 || true; echo
    if [[ "$a1" == "$a2" ]]; then echo "$a1"; return 0; else echo " - مطابقت ندارند؛ دوباره تلاش کن."; fi
  done
}

write_summary() { # $1=text
  local f="/root/setup_summary.txt"
  umask 077
  printf "%s\n" "$1" > "$f"
  chmod 600 "$f"
  echo; echo "📄 خلاصهٔ نصب در: $f (فقط root)"
}

trap 'err "نصب با خطا متوقف شد (exit code $?). لاگ بالا را بررسی کن."' ERR

########################################
# 0) Interactive inputs
########################################
gather_inputs() {
  echo "=== پیکربندی تعاملی نصب ==="

  TIMEZONE=$(prompt_value "Timezone" "Etc/UTC")

  # Python version selector (default 3.10)
  PY_VERSION=$(prompt_value "نسخه Python (3.10 پایدار، یا 3.11/3.12/3.13)" "3.10")

  # PostgreSQL (local, version 17)
  POSTGRES_PORT=$(prompt_value "پورت PostgreSQL (لوکال)" "5432")
  POSTGRES_USER=$(prompt_value "نام کاربری PostgreSQL" "postgres")
  POSTGRES_PASSWORD=$(prompt_secret "پسورد PostgreSQL")
  POSTGRES_DB=$(prompt_value "نام دیتابیس پیش‌فرض" "appdb")

  # Metabase metadata DB (on Postgres local)
  MB_DB_NAME=$(prompt_value "نام دیتابیس متابیس (metadata)" "metabase")
  MB_DB_USER=$(prompt_value "یوزر دیتابیس متابیس" "metabase")
  MB_DB_PASSWORD=$(prompt_secret "پسورد دیتابیس متابیس")

  # pgAdmin (local web)
  PGADMIN_PORT=$(prompt_value "پورت pgAdmin (لوکال)" "5050")
  PGADMIN_EMAIL=$(prompt_value "ایمیل ادمین pgAdmin (اولین ورود را خودت می‌سازی)" "admin@example.com")

  # code-server (public)
  CODE_SERVER_PORT=$(prompt_value "پورت code-server (اینترنتی)" "8443")
  CODE_SERVER_PASSWORD=$(prompt_secret "پسورد ورود code-server (روی نت)")

  echo; echo "✅ ورودی‌ها دریافت شد."
}

########################################
# 1) System & basics
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
  apt-get install -y apt-transport-https ca-certificates curl gnupg unzip git nano zip ufw software-properties-common lsb-release -qq
  ok "Base packages installed."
}

ensure_hostname_mapping() {
  local hn; hn="$(hostname)"
  if ! grep -Eq "127\.0\.1\.1\s+.*\b${hn}\b" /etc/hosts; then
    log "Fixing /etc/hosts mapping for hostname: $hn"
    echo "127.0.1.1 ${hn} ${hn%%.*}" >> /etc/hosts
    ok "/etc/hosts updated."
  fi
}

########################################
# 2) Python (selectable; default 3.10)
########################################
install_python_selected() {
  log "Installing Python ${PY_VERSION}..."
  case "$PY_VERSION" in
    3.10)
      apt-get install -y python3 python3-venv python3-dev python3-distutils python3-pip -qq
      update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3 1 || true
      update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3 1 || true
      ;;
    3.11|3.12|3.13)
      add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
      apt-get update -qq
      apt-get install -y "python${PY_VERSION}" "python${PY_VERSION}-venv" "python${PY_VERSION}-dev" "python${PY_VERSION}-distutils" -qq
      if ! command -v "pip${PY_VERSION}" >/dev/null 2>&1; then
        "/usr/bin/python${PY_VERSION}" -m ensurepip --upgrade || true
      fi
      update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PY_VERSION}" 1
      if command -v "pip${PY_VERSION}" >/dev/null 2>&1; then
        ln -sf "$(command -v "pip${PY_VERSION}")" /usr/bin/pip3 || true
      else
        apt-get install -y python3-pip -qq || true
      fi
      ;;
    *) err "نسخه Python نامعتبر است. 3.10/3.11/3.12/3.13"; exit 1 ;;
  esac
  ok "Python ${PY_VERSION} ready."
}

########################################
# 3) PostgreSQL 17 (PGDG only, local-only) — \gexec + scram
########################################
install_postgresql_local() {
  log "Adding official PostgreSQL (PGDG) repo & installing v17 only..."
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
  . /etc/os-release
  echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt ${UBUNTU_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  # جلوگیری از ساخت خودکار کلاستر و پین روی نسخه 17
  sed -i 's/^#\?create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf || true
  apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17 -qq

  # ساخت کلاستر main با تنظیمات دلخواه
  pg_createcluster 17 main -- --auth-local=peer --auth-host=scram-sha-256
  local CONF_DIR="/etc/postgresql/17/main"
  local POSTGRESQL_CONF="${CONF_DIR}/postgresql.conf"
  local PG_HBA_CONF="${CONF_DIR}/pg_hba.conf"

  # Bind و Port
  if grep -qE '^\s*#?\s*listen_addresses' "$POSTGRESQL_CONF"; then
    sed -i "s/^#\?listen_addresses.*/listen_addresses = '127.0.0.1'/" "$POSTGRESQL_CONF"
  else
    echo "listen_addresses = '127.0.0.1'" >> "$POSTGRESQL_CONF"
  fi
  if grep -qE '^\s*#?\s*port\s*=' "$POSTGRESQL_CONF"; then
    sed -i "s/^#\?port.*/port = ${POSTGRES_PORT}/" "$POSTGRESQL_CONF"
  else
    echo "port = ${POSTGRES_PORT}" >> "$POSTGRESQL_CONF"
  fi

  # اطمینان از scram برای لوکال
  if ! grep -qE '^\s*host\s+all\s+all\s+127\.0\.0\.1/32\s+scram-sha-256' "$PG_HBA_CONF"; then
    echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA_CONF"
  fi

  systemctl enable --now postgresql

  # ساخت role/db با \gexec (ایمن)
  sudo -H -u postgres psql --set=ON_ERROR_STOP=1 \
    --set=usr="${POSTGRES_USER}" \
    --set=pw="${POSTGRES_PASSWORD}" \
    --set=db="${POSTGRES_DB}" \
    --set=mbusr="${MB_DB_USER}" \
    --set=mbpw="${MB_DB_PASSWORD}" \
    --set=mbdb="${MB_DB_NAME}" \
    --file - <<'PSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'usr', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'usr') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'usr')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'mbusr', :'mbpw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'mbusr') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'mbdb', :'mbusr')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'mbdb') \gexec
PSQL

  ok "PostgreSQL 17 bound to 127.0.0.1:${POSTGRES_PORT} (conf: $CONF_DIR)."
}

########################################
# 4) pgAdmin (local, venv + gunicorn + systemd)
########################################
install_pgadmin_local() {
  log "Installing pgAdmin 4 (venv, gunicorn) on 127.0.0.1:${PGADMIN_PORT} ..."

  apt-get -y purge pgadmin4 pgadmin4-web || true
  rm -f /etc/apt/sources.list.d/pgadmin4.list || true

  apt-get update -qq
  apt-get install -y python3-venv python3-pip libpq5 libldap-2.5-0 libsasl2-2 libssl3 libffi8 -qq

  install -d -m 0755 /opt/pgadmin
  python3 -m venv /opt/pgadmin/venv
  /opt/pgadmin/venv/bin/pip install --upgrade pip wheel >/dev/null
  /opt/pgadmin/venv/bin/pip install --no-cache-dir pgadmin4 gunicorn >/dev/null

  install -d -m 0755 /opt/pgadmin/data
  cat >/opt/pgadmin/config_local.py <<EOF
SERVER_MODE = True
DEFAULT_SERVER = '127.0.0.1'
DEFAULT_SERVER_PORT = ${PGADMIN_PORT}
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
ENHANCED_COOKIE_PROTECTION = True
SQLITE_PATH = '/opt/pgadmin/data/pgadmin4.db'
STORAGE_DIR = '/opt/pgadmin/data/storage'
EOF
  chown -R root:root /opt/pgadmin
  chmod -R 700 /opt/pgadmin/data

  cat >/etc/systemd/system/pgadmin4.service <<EOF
[Unit]
Description=pgAdmin 4 (gunicorn)
After=network.target
[Service]
Type=simple
User=root
Group=root
Environment=PYTHONPATH=/opt/pgadmin
Environment=PGADMIN_CONFIG_LOCAL=/opt/pgadmin/config_local.py
WorkingDirectory=/opt/pgadmin
ExecStart=/opt/pgadmin/venv/bin/gunicorn --workers 2 --threads 4 --bind 127.0.0.1:${PGADMIN_PORT} pgadmin4.pgAdmin4:app
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pgadmin4
  ok "pgAdmin running on 127.0.0.1:${PGADMIN_PORT}"
}

########################################
# 5) code-server (PUBLIC, root, latest)
########################################
install_codeserver_local() {
  log "Installing latest code-server (root, PUBLIC access)..."
  curl -fsSL https://code-server.dev/install.sh | sh
  umask 077
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: "${CODE_SERVER_PASSWORD}"
cert: false
EOF
  cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server (root)
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/code-server --bind-addr 0.0.0.0:${CODE_SERVER_PORT} --auth password
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now code-server
  ok "code-server listening on 0.0.0.0:${CODE_SERVER_PORT} (PUBLIC)"
}

########################################
# 6) Docker & Compose (latest)
########################################
install_docker() {
  log "Installing Docker Engine & Compose..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
  systemctl enable --now docker
  ok "Docker ready."
}

########################################
# 7) UFW (SSH/Web + code-server public)
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
  ufw allow ${CODE_SERVER_PORT}/tcp  # code-server PUBLIC
  # 5432/5050 لوکال هستند
  ufw --force enable
  ok "UFW configured."
}

########################################
# 8) Docker stack: pg-gateway + Metabase + NPM + Portainer
########################################
write_stack() {
  log "Writing Docker stack..."
  mkdir -p /opt/stack/{metabase,npm,portainer}
  cat > /opt/stack/.env <<EOF
TIMEZONE=${TIMEZONE}
MB_DB_NAME=${MB_DB_NAME}
MB_DB_USER=${MB_DB_USER}
MB_DB_PASSWORD=${MB_DB_PASSWORD}
PG_PORT=${POSTGRES_PORT}
EOF

  cat > /opt/stack/docker-compose.yml <<'YAML'
name: webstack
services:
  pg-gateway:
    image: alpine/socat:latest
    command: ["tcp-listen:5432,fork,reuseaddr","tcp-connect:host.docker.internal:${PG_PORT}"]
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
    extra_hosts:
      - "host.docker.internal:host-gateway"

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
  log "Starting Docker stack (pull latest images)..."
  cd /opt/stack
  docker compose pull
  docker compose up -d
  ok "Stack is up."
}

########################################
# 9) Final Summary
########################################
print_summary() {
  local SUM="
==================== خلاصهٔ نصب ====================
[عمومی/وب]
- Nginx Proxy Manager (Admin):  http://YOUR_SERVER_IP:81
- Portainer:                    https://YOUR_SERVER_IP:9443

[لوکال/دیتابیس]
- PostgreSQL 17: 127.0.0.1:${POSTGRES_PORT}
  - User: ${POSTGRES_USER}
  - Password: ${POSTGRES_PASSWORD}
  - Default DB: ${POSTGRES_DB}

- Metabase (پشت NPM منتشر کن)
  - Metadata DB → ${MB_DB_NAME} (owner: ${MB_DB_USER})
  - اتصال به Postgres از طریق pg-gateway (بدون اکسپوز 5432) روی پورت هاست ${POSTGRES_PORT}

- pgAdmin (لوکال، gunicorn)
  - Bind: 127.0.0.1:${PGADMIN_PORT}
  - اولین ورود: با ایمیل ${PGADMIN_EMAIL} خودت اکانت بساز.

[IDE]
- code-server (PUBLIC)
  - URL:  http://YOUR_SERVER_IP:${CODE_SERVER_PORT}
  - Password: ${CODE_SERVER_PASSWORD}
  - User: root

[Firewall/UFW]
- باز: 22(SSH), 80, 81, 443, 9443, ${CODE_SERVER_PORT}
- بسته: 5432 (Postgres), ${PGADMIN_PORT} (pgAdmin)

[Proxy Host ها (در NPM)]
- pgAdmin:
  - Domain: pgadmin.yourdomain.com
  - Forward Host/IP: host.docker.internal
  - Forward Port: ${PGADMIN_PORT}
  - SSL: Let’s Encrypt + Force SSL + HTTP/2

- Metabase:
  - Domain: metabase.yourdomain.com
  - Forward Host/IP: metabase
  - Forward Port: 3000
  - SSL: Let’s Encrypt + Force SSL + HTTP/2

- code-server (اگر خواستی پشت NPM ببری):
  - Domain: ide.yourdomain.com
  - Forward Host/IP: host.docker.internal
  - Forward Port: ${CODE_SERVER_PORT}
  - SSL: Let’s Encrypt + Force SSL + HTTP/2
===================================================
"
  echo "$SUM"
  write_summary "$SUM"
}

########################################
# MAIN
########################################
main() {
  need_root
  gather_inputs
  update_upgrade
  install_basics
  ensure_hostname_mapping
  install_python_selected
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
