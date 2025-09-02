#!/usr/bin/env bash
# =============================================================================
#  اسم:   setup_server.sh
#  هدف:   راه‌اندازی سریع سرور توسعه/دیتا با Postgres 17، pgAdmin (لوکال)،
#         code-server (پابلیک)، NPM/Portainer/Metabase (Docker)، و فایروال UFW.
#  وضعیت: Idempotent (قابل اجرای مجدد بدون خطا)
#  نویسنده: Alyssa (الیسا)
# =============================================================================
set -euo pipefail

########################################
# Helpers
########################################
log()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[DONE]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

trap 'err "اسکریپت در خط $LINENO با خطا متوقف شد (exit $?)."' ERR

need_root(){ [[ $EUID -eq 0 ]] || { err "این اسکریپت باید با sudo/root اجرا شود."; exit 1; }; }

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
    [[ -n "$a1" ]] || { echo " - خالی نباشد."; continue; }
    read -r -s -p "تکرار $q: " a2 || true; echo
    if [[ "$a1" == "$a2" ]]; then echo "$a1"; return 0; else echo " - مطابقت ندارند؛ دوباره."; fi
  done
}

write_summary(){ # $1=text
  local f="/root/setup_summary.txt"
  umask 077
  printf "%s\n" "$1" > "$f"
  chmod 600 "$f"
  echo "📄 خلاصه در: $f"
}

########################################
# 0) Interactive inputs
########################################
gather_inputs() {
  echo "=== پیکربندی تعاملی ==="
  TIMEZONE=$(prompt_value "Timezone" "Etc/UTC")
  PY_VERSION=$(prompt_value "نسخه Python (3.10/3.11/3.12/3.13)" "3.10")

  # PostgreSQL remote?
  WANT_REMOTE=$(prompt_value "به Postgres از بیرون نیاز داری؟ (yes/no)" "no")
  if [[ "$WANT_REMOTE" == "yes" ]]; then
    POSTGRES_BIND_ADDRESS="0.0.0.0"
    POSTGRES_REMOTE_IP=$(prompt_value "IP مجاز برای اتصال به Postgres (یک IP)")
  else
    POSTGRES_BIND_ADDRESS="127.0.0.1"
    POSTGRES_REMOTE_IP=""
  fi
  POSTGRES_PORT=$(prompt_value "پورت PostgreSQL" "5432")
  POSTGRES_USER=$(prompt_value "یوزر PostgreSQL" "postgres")
  POSTGRES_PASSWORD=$(prompt_secret "پسورد PostgreSQL")
  POSTGRES_DB=$(prompt_value "نام دیتابیس اولیه" "appdb")

  # Metabase metadata (on local Postgres)
  MB_DB_NAME=$(prompt_value "نام دیتابیس متابیس" "metabase")
  MB_DB_USER=$(prompt_value "یوزر متابیس" "metabase")
  MB_DB_PASSWORD=$(prompt_secret "پسورد متابیس")

  # pgAdmin (local)
  PGADMIN_PORT=$(prompt_value "پورت pgAdmin (لوکال)" "5050")
  PGADMIN_EMAIL=$(prompt_value "ایمیل ادمین pgAdmin (ساخت در اولین ورود)" "admin@example.com")

  # code-server (PUBLIC)
  CODE_SERVER_PORT=$(prompt_value "پورت code-server (پابلیک)" "8443")
  CODE_SERVER_PASSWORD=$(prompt_secret "پسورد code-server")

  ok "ورودی‌ها دریافت شد."
}

########################################
# 1) System prep
########################################
prepare_system() {
  log "System update/upgrade + base tools"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y dist-upgrade -qq
  apt-get -y autoremove -qq
  timedatectl set-timezone "$TIMEZONE" || true
  apt-get install -y apt-transport-https ca-certificates curl gnupg unzip git nano zip ufw software-properties-common lsb-release -qq
  # hostname fix (sudo resolve)
  local hn; hn="$(hostname)"
  grep -q "127.0.1.1.*${hn}" /etc/hosts || echo "127.0.1.1 ${hn} ${hn%%.*}" >> /etc/hosts
  ok "System ready."
}

########################################
# 2) Python
########################################
install_python_selected() {
  log "Installing Python ${PY_VERSION}"
  case "$PY_VERSION" in
    3.10)
      apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip -qq
      update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
      ;;
    3.11|3.12|3.13)
      add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
      apt-get update -qq
      apt-get install -y "python${PY_VERSION}" "python${PY_VERSION}-venv" "python${PY_VERSION}-dev" -qq
      "/usr/bin/python${PY_VERSION}" -m ensurepip --upgrade || true
      update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PY_VERSION}" 1
      ;;
    *) err "نسخه نامعتبر Python."; exit 1 ;;
  esac
  python3 -m pip -q install --upgrade pip
  ok "Python ${PY_VERSION} آماده است."
}

########################################
# 3) PostgreSQL 17 (PGDG, idempotent)
########################################
install_postgresql_host() {
  log "Installing PostgreSQL 17 (PGDG, idempotent)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq

  # مهم: اول postgresql-common، بعد غیرفعالسازی ساخت خودکار کلاستر
  apt-get install -y postgresql-common -qq
  sed -i 's/^#\?create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf || true

  apt-get install -y postgresql-17 postgresql-client-17 -qq

  # ساخت کلاستر فقط اگر نبود
  if pg_lsclusters 2>/dev/null | awk '{print $1,$2}' | grep -q "^17 main$"; then
    log "Cluster 17/main وجود دارد؛ از ساخت صرف‌نظر می‌کنیم."
  else
    log "Creating cluster 17/main ..."
    pg_createcluster 17 main -- --auth-local=peer --auth-host=scram-sha-256
  fi

  local PG_CONF="/etc/postgresql/17/main/postgresql.conf"
  local PG_HBA="/etc/postgresql/17/main/pg_hba.conf"

  # Bind/Port
  grep -qE '^\s*#?\s*listen_addresses' "$PG_CONF" \
    && sed -i "s/^#\?listen_addresses.*/listen_addresses = '${POSTGRES_BIND_ADDRESS}'/" "$PG_CONF" \
    || echo "listen_addresses = '${POSTGRES_BIND_ADDRESS}'" >> "$PG_CONF"

  grep -qE '^\s*#?\s*port\s*=' "$PG_CONF" \
    && sed -i "s/^#\?port.*/port = ${POSTGRES_PORT}/" "$PG_CONF" \
    || echo "port = ${POSTGRES_PORT}" >> "$PG_CONF"

  # pg_hba: scram لوکال و در صورت نیاز ریموت
  grep -qE '^\s*host\s+all\s+all\s+127\.0\.0\.1/32\s+scram-sha-256' "$PG_HBA" \
    || echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"

  if [[ -n "${POSTGRES_REMOTE_IP}" ]]; then
    grep -qE "^\s*host\s+all\s+all\s+${POSTGRES_REMOTE_IP//./\\.}/32\s+scram-sha-256" "$PG_HBA" \
      || echo "host    all             all             ${POSTGRES_REMOTE_IP}/32     scram-sha-256" >> "$PG_HBA"
  fi

  systemctl enable postgresql
  systemctl restart postgresql

  # Roles & DBs (idempotent via \gexec)
  sudo -H -u postgres psql --set=ON_ERROR_STOP=1 \
    --set=usr="${POSTGRES_USER}" \
    --set=pw="${POSTGRES_PASSWORD}" \
    --set=db="${POSTGRES_DB}" \
    --set=mbusr="${MB_DB_USER}" \
    --set=mbpw="${MB_DB_PASSWORD}" \
    --set=mbdb="${MB_DB_NAME}" \
    --file - <<'PSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'usr', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'usr') \gexec;

SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'usr')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec;

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'mbusr', :'mbpw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'mbusr') \gexec;

SELECT format('CREATE DATABASE %I OWNER %I', :'mbdb', :'mbusr')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'mbdb') \gexec;
PSQL

  ok "PostgreSQL 17 روی ${POSTGRES_BIND_ADDRESS}:${POSTGRES_PORT} آماده است."
}

########################################
# 4) pgAdmin (venv + gunicorn; local only)
########################################
install_pgadmin_host() {
  log "Installing pgAdmin 4 (venv+gunicorn) on 127.0.0.1:${PGADMIN_PORT}"
  apt-get install -y python3-venv python3-pip libpq5 libldap-2.5-0 libsasl2-2 libssl3 libffi8 -qq

  install -d -m 0755 /opt/pgadmin
  if [[ ! -d /opt/pgadmin/venv ]]; then
    python3 -m venv /opt/pgadmin/venv
  fi
  /opt/pgadmin/venv/bin/pip -q install --upgrade pip wheel
  /opt/pgadmin/venv/bin/pip -q install --no-cache-dir pgadmin4 gunicorn

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
  ok "pgAdmin روی 127.0.0.1:${PGADMIN_PORT} اجراست."
}

########################################
# 5) code-server (PUBLIC, root)
########################################
install_codeserver_host() {
  log "Installing code-server (PUBLIC) on 0.0.0.0:${CODE_SERVER_PORT}"
  curl -fsSL https://code-server.dev/install.sh | sh
  umask 077
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: "${CODE_SERVER_PASSWORD}"
cert: false
EOF
  systemctl enable --now code-server
  systemctl restart code-server
  ok "code-server روی 0.0.0.0:${CODE_SERVER_PORT} بالا است."
}

########################################
# 6) Docker & Compose
########################################
install_docker() {
  log "Installing Docker & Compose plugin"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
  systemctl enable --now docker
  ok "Docker آماده شد."
}

########################################
# 7) UFW
########################################
configure_ufw() {
  log "Configuring UFW rules"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH || ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 81/tcp         # NPM Admin
  ufw allow 9443/tcp       # Portainer
  ufw allow ${CODE_SERVER_PORT}/tcp  # code-server PUBLIC
  if [[ -n "${POSTGRES_REMOTE_IP}" ]]; then
    ufw allow from "${POSTGRES_REMOTE_IP}" to any port "${POSTGRES_PORT}" proto tcp
  fi
  ufw --force enable
  ok "UFW فعال است."
}

########################################
# 8) Docker stack (NPM/Portainer/Metabase + pg-gateway)
########################################
setup_docker_stack() {
  log "Writing docker-compose stack"
  mkdir -p /opt/stack/{npm,portainer,metabase}
  cat > /opt/stack/.env <<EOF
TIMEZONE=${TIMEZONE}
MB_DB_NAME=${MB_DB_NAME}
MB_DB_USER=${MB_DB_USER}
MB_DB_PASSWORD=${MB_DB_PASSWORD}
PG_PORT=${POSTGRES_PORT}
EOF

  cat > /opt/stack/docker-compose.yml <<'YAML'
version: "3.8"
services:
  pg-gateway:
    image: alpine/socat:latest
    command: ["tcp-listen:5432,fork,reuseaddr","tcp-connect:host.docker.internal:${PG_PORT}"]
    restart: unless-stopped
    networks: [ backend ]
    extra_hosts: [ "host.docker.internal:host-gateway" ]

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
    extra_hosts: [ "host.docker.internal:host-gateway" ]

  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports: [ "9443:9443" ]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer/data:/data
    networks: [ backend ]

networks:
  backend:
    driver: bridge
YAML

  ( cd /opt/stack && docker compose pull && docker compose up -d )
  ok "Docker stack is up."
}

########################################
# 9) Sanity checks + Summary
########################################
sanity_checks_and_summary() {
  local ip; ip="$(curl -s ifconfig.me || echo 'YOUR_SERVER_IP')"

  echo -e "\n==== LISTEN PORTS ===="
  ss -ltnp | egrep "(:80|:81|:443|:9443|:${PGADMIN_PORT}|:${CODE_SERVER_PORT})\b" || true

  echo -e "\n==== LOCAL CURL TESTS ===="
  for u in "http://127.0.0.1:81" "http://127.0.0.1:80" "https://127.0.0.1:9443" "http://127.0.0.1:${PGADMIN_PORT}" "http://127.0.0.1:${CODE_SERVER_PORT}"; do
    echo -n "$u -> "; curl -skI --max-time 5 "$u" | head -n1 || echo "FAIL"
  done

  echo -e "\n==== DOCKER COMPOSE PS ===="
  (cd /opt/stack && docker compose ps) || true

  # Summary (با نمایش کامل یوزرنیم/پسورد طبق خواست)
  local REMOTE_NOTE=""
  if [[ -n "${POSTGRES_REMOTE_IP}" ]]; then
    REMOTE_NOTE="(باز برای ${POSTGRES_REMOTE_IP})"
  else
    REMOTE_NOTE="(فقط لوکال)"
  fi

  local SUMMARY="
==================== خلاصهٔ نصب ====================
[عمومی]
- NPM (Admin):        http://${ip}:81
  * Default login (اولین ورود): admin@example.com / changeme
- Portainer:          https://${ip}:9443
- code-server (root): http://${ip}:${CODE_SERVER_PORT}
  * Password: ${CODE_SERVER_PASSWORD}

[لوکال]
- pgAdmin:            http://127.0.0.1:${PGADMIN_PORT}
  * First admin email: ${PGADMIN_EMAIL}

[PostgreSQL 17]
- Bind: ${POSTGRES_BIND_ADDRESS}:${POSTGRES_PORT} ${REMOTE_NOTE}
- User: ${POSTGRES_USER}
- Pass: ${POSTGRES_PASSWORD}
- DB:   ${POSTGRES_DB}

[Metabase]
- Metadata DB: ${MB_DB_NAME} / ${MB_DB_USER} / ${MB_DB_PASSWORD}
- منتشر از طریق NPM → Forward Host: metabase, Port: 3000 (SSL فعال)

[Firewall/UFW]
- Open: 22,80,81,443,9443,${CODE_SERVER_PORT} $( [[ -n "$POSTGRES_REMOTE_IP" ]] && echo ", ${POSTGRES_PORT} فقط برای ${POSTGRES_REMOTE_IP}" )
- Closed: 5432 به‌جز برای IP مجاز (اگر تعریف شده)

[راهنمای NPM]
- pgAdmin → Domain: pgadmin.yourdomain → Forward host: host.docker.internal → Port: ${PGADMIN_PORT} → SSL
- code-server → Domain: ide.yourdomain → Forward host: host.docker.internal → Port: ${CODE_SERVER_PORT} → SSL
- Metabase → Domain: metabase.yourdomain → Forward host: metabase → Port: 3000 → SSL
===================================================
"
  echo "$SUMMARY"
  write_summary "$SUMMARY"
}

########################################
# MAIN
########################################
main() {
  need_root
  gather_inputs
  prepare_system
  install_python_selected
  install_postgresql_host
  install_pgadmin_host
  install_codeserver_host
  install_docker
  configure_ufw
  setup_docker_stack
  sanity_checks_and_summary
  ok "تمام شد."
}

main "$@"
