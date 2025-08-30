#!/usr/bin/env bash
#
# =================================================================
#  الیسا: اسکریپت جامع راه‌اندازی سرور توسعه و تحلیل داده
#  نسخه: 2.0.0
#  تغییرات اصلی:
#    - افزودن قابلیت دسترسی ریموت امن به PostgreSQL
#    - بهبود پایداری و لاگ‌نویسی برای دیباگ آسان‌تر
#    - اصلاح و تقویت قوانین فایروال (UFW)
#    - به‌روزرسانی خلاصه نهایی با جزئیات کامل
# =================================================================
#
set -euo pipefail

########################################
# Helpers
########################################
log() { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[DONE]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }

# الیسا: این trap در صورت بروز هرگونه خطا، پیامی مشخص همراه با شماره خط نمایش می‌دهد.
trap 'err "اسکریپت در خط $LINENO با خطا متوقف شد (exit code $?). لاگ بالا را برای علت‌یابی بررسی کنید."' ERR

need_root(){ [[ $EUID -eq 0 ]] || { err "این اسکریپت باید با دسترسی root (sudo) اجرا شود."; exit 1; }; }

prompt_value() { # $1=question  $2=default
  local q="$1" def="${2-}" ans=""
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$q: " ans || true
    while [[ -z "$ans" ]]; do read -r -p "$q (این مقدار نمی‌تواند خالی باشد): " ans || true; done
  fi
  echo "$ans"
}

prompt_secret() { # $1=question
  local q="$1" a1="" a2=""
  while true; do
    read -r -s -p "$q (ورودی مخفی است): " a1 || true; echo
    [[ -n "$a1" ]] || { warn " - مقدار نمی‌تواند خالی باشد."; continue; }
    read -r -s -p "لطفاً $q را تکرار کنید: " a2 || true; echo
    if [[ "$a1" == "$a2" ]]; then echo "$a1"; return 0; else warn " - مقادیر مطابقت ندارند؛ لطفاً دوباره تلاش کنید."; fi
  done
}

write_summary() { # $1=text
  local f="/root/setup_summary.txt"
  umask 077
  printf "%s\n" "$1" > "$f"
  chmod 600 "$f"
  echo; echo "📄 خلاصهٔ کامل نصب در فایل زیر ذخیره شد (فقط برای کاربر root قابل دسترسی است): $f"
}

########################################
# 0) ورودی‌های تعاملی
########################################
gather_inputs() {
  log "=== مرحله ۰: دریافت پیکربندی تعاملی ==="

  TIMEZONE=$(prompt_value "Timezone را وارد کنید" "Etc/UTC")
  PY_VERSION=$(prompt_value "نسخه Python مورد نظر (3.10 پایدار، یا 3.11/3.12/3.13)" "3.10")

  # الیسا: نیازمندی جدید: امکان اتصال از راه دور به دیتابیس
  if [[ $(prompt_value "آیا به PostgreSQL از سرور دیگری نیاز به اتصال دارید؟ (yes/no)" "no") == "yes" ]]; then
    POSTGRES_BIND_ADDRESS="0.0.0.0" # Bind to all interfaces
    POSTGRES_REMOTE_IP=$(prompt_value "IP سرور مجازی که می‌خواهید به دیتابیس متصل شود را وارد کنید")
  else
    POSTGRES_BIND_ADDRESS="127.0.0.1" # Local access only
    POSTGRES_REMOTE_IP=""
  fi

  POSTGRES_PORT=$(prompt_value "پورت PostgreSQL" "5432")
  POSTGRES_USER=$(prompt_value "نام کاربری ادمین PostgreSQL" "pgadmin")
  POSTGRES_PASSWORD=$(prompt_secret "پسورد ادمین PostgreSQL")
  POSTGRES_DB=$(prompt_value "نام دیتابیس اصلی برنامه" "appdb")

  MB_DB_NAME=$(prompt_value "نام دیتابیس برای Metabase (metadata)" "metabase_db")
  MB_DB_USER=$(prompt_value "نام کاربری دیتابیس Metabase" "metabase_user")
  MB_DB_PASSWORD=$(prompt_secret "پسورد دیتابیس Metabase")

  PGADMIN_PORT=$(prompt_value "پورت pgAdmin (فقط روی لوکال هاست)" "5050")
  PGADMIN_EMAIL=$(prompt_value "ایمیل ادمین برای ورود اولیه به pgAdmin" "admin@example.com")

  CODE_SERVER_PORT=$(prompt_value "پورت code-server (این پورت عمومی خواهد بود)" "8443")
  CODE_SERVER_PASSWORD=$(prompt_secret "پسورد ورود به code-server")

  ok "تمام ورودی‌ها با موفقیت دریافت شد."
}

########################################
# 1) آماده‌سازی سیستم
########################################
prepare_system() {
  log "=== مرحله ۱: آماده‌سازی و به‌روزرسانی سیستم ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y dist-upgrade -qq
  apt-get -y autoremove -qq
  timedatectl set-timezone "$TIMEZONE" || warn "تنظیم Timezone با خطا مواجه شد اما ادامه می‌دهیم."
  apt-get install -y apt-transport-https ca-certificates curl gnupg unzip git nano zip ufw software-properties-common lsb-release -qq
  
  # الیسا: این بخش برای جلوگیری از خطاهای مربوط به hostname در برخی سرویس‌ها ضروری است.
  local hn; hn="$(hostname)"
  if ! grep -q "127.0.1.1.*${hn}" /etc/hosts; then
    echo "127.0.1.1 ${hn}" >> /etc/hosts
    log "Hostname ($hn) به /etc/hosts اضافه شد."
  fi

  ok "سیستم آماده و بسته‌های پایه نصب شدند."
}

########################################
# 2) نصب Python
########################################
install_python_selected() {
  log "=== مرحله ۲: نصب Python نسخه ${PY_VERSION} ==="
  case "$PY_VERSION" in
    3.10)
      apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip -qq
      update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
      ;;
    3.11|3.12|3.13)
      add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
      apt-get update -qq
      apt-get install -y "python${PY_VERSION}" "python${PY_VERSION}-venv" "python${PY_VERSION}-dev" -qq
      # الیسا: نصب pip به صورت جداگانه برای نسخه‌های جدید پایتون
      curl -sS https://bootstrap.pypa.io/get-pip.py | "/usr/bin/python${PY_VERSION}"
      update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PY_VERSION}" 1
      ;;
    *) err "نسخه Python نامعتبر است: $PY_VERSION. لطفاً یکی از نسخه‌های 3.10/3.11/3.12/3.13 را انتخاب کنید."; exit 1 ;;
  esac
  python3 -m pip install --upgrade pip >/dev/null
  ok "Python ${PY_VERSION} با موفقیت نصب و به عنوان نسخه پیش‌فرض تنظیم شد."
}

########################################
# 3) نصب PostgreSQL 17 (نصب روی هاست)
########################################
install_postgresql_host() {
  log "=== مرحله ۳: نصب PostgreSQL 17 روی هاست ==="
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  
  # جلوگیری از ساخت کلاستر پیش‌فرض برای کنترل کامل روی تنظیمات
  sed -i 's/^#\?create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf || true
  apt-get install -y postgresql-17 postgresql-client-17 -qq

  pg_createcluster 17 main -- --auth-local=peer --auth-host=scram-sha-256
  
  local PG_CONF="/etc/postgresql/17/main/postgresql.conf"
  local PG_HBA="/etc/postgresql/17/main/pg_hba.conf"

  log "پیکربندی PostgreSQL برای اتصال از ${POSTGRES_BIND_ADDRESS}:${POSTGRES_PORT}..."
  sed -i "s/^#\?listen_addresses.*/listen_addresses = '${POSTGRES_BIND_ADDRESS}'/" "$PG_CONF"
  sed -i "s/^#\?port.*/port = ${POSTGRES_PORT}/" "$PG_CONF"
  
  # الیسا: اطمینان از اینکه اتصال لوکال با scram-sha-256 امن شده است.
  echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"
  
  if [[ -n "$POSTGRES_REMOTE_IP" ]]; then
    log "افزودن قانون دسترسی برای IP ریموت: ${POSTGRES_REMOTE_IP}"
    echo "host    all             all             ${POSTGRES_REMOTE_IP}/32     scram-sha-256" >> "$PG_HBA"
  fi

  systemctl restart postgresql
  systemctl enable postgresql

  log "ساخت کاربران و دیتابیس‌ها..."
  # الیسا: استفاده از `\gexec` برای جلوگیری از خطاهای "already exists" و افزایش امنیت
  sudo -u postgres psql --set=ON_ERROR_STOP=1 \
    --set=usr="${POSTGRES_USER}" \
    --set=pw="${POSTGRES_PASSWORD}" \
    --set=db="${POSTGRES_DB}" \
    --set=mbusr="${MB_DB_USER}" \
    --set=mbpw="${MB_DB_PASSWORD}" \
    --set=mbdb="${MB_DB_NAME}" \
    --file - <<'PSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'usr', :'pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'usr') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'usr')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'mbusr', :'mbpw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'mbusr') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'mbdb', :'mbusr')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'mbdb') \gexec
PSQL

  ok "PostgreSQL 17 با موفقیت نصب و پیکربندی شد."
}

########################################
# 4) نصب pgAdmin (روی هاست با venv)
########################################
install_pgadmin_host() {
  log "=== مرحله ۴: نصب pgAdmin 4 روی هاست (در venv) ==="
  apt-get install -y libpq-dev python3-dev -qq # پیش‌نیازهای کامپایل
  
  install -d -m 0755 /opt/pgadmin
  python3 -m venv /opt/pgadmin/venv
  /opt/pgadmin/venv/bin/pip install --upgrade pip wheel >/dev/null
  /opt/pgadmin/venv/bin/pip install --no-cache-dir pgadmin4 gunicorn >/dev/null

  install -d -m 0755 /opt/pgadmin/data
  cat >/opt/pgadmin/config_local.py <<EOF
SERVER_MODE = True
DEFAULT_SERVER = '127.0.0.1'
DEFAULT_SERVER_PORT = ${PGADMIN_PORT}
SESSION_COOKIE_SAMESITE = 'Lax'
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SQLITE_PATH = '/opt/pgadmin/data/pgadmin4.db'
LOG_FILE = '/var/log/pgadmin4.log'
STORAGE_DIR = '/opt/pgadmin/data/storage'
EOF
  chown -R root:root /opt/pgadmin
  chmod -R 700 /opt/pgadmin/data
  touch /var/log/pgadmin4.log

  cat >/etc/systemd/system/pgadmin4.service <<EOF
[Unit]
Description=pgAdmin 4 Web UI
After=network.target

[Service]
Type=simple
User=root
Group=root
Environment="PGADMIN_SETUP_EMAIL=${PGADMIN_EMAIL}"
Environment="PGADMIN_SETUP_PASSWORD=dummy_password_will_not_be_used" # Set on first login
Environment="PGADMIN_CONFIG_LOCAL=/opt/pgadmin/config_local.py"
ExecStart=/opt/pgadmin/venv/bin/gunicorn --workers 1 --threads 4 --bind 127.0.0.1:${PGADMIN_PORT} pgadmin4:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pgadmin4
  ok "pgAdmin روی 127.0.0.1:${PGADMIN_PORT} در حال اجراست. (برای دسترسی عمومی از NPM استفاده کنید)"
}

########################################
# 5) نصب code-server (روی هاست، دسترسی عمومی)
########################################
install_codeserver_host() {
  log "=== مرحله ۵: نصب code-server روی هاست (دسترسی عمومی) ==="
  curl -fsSL https://code-server.dev/install.sh | sh
  umask 077
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: "${CODE_SERVER_PASSWORD}"
cert: false
EOF
  # الیسا: سرویس systemd برای مدیریت بهتر code-server
  systemctl enable --now code-server
  ok "code-server روی 0.0.0.0:${CODE_SERVER_PORT} در حال اجراست."
  warn "code-server با کاربر root اجرا می‌شود. این دسترسی بسیار قدرتمند و حساس است."
}

########################################
# 6) نصب Docker و Docker Compose
########################################
install_docker() {
  log "=== مرحله ۶: نصب Docker Engine و Docker Compose ==="
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
  systemctl enable --now docker
  ok "Docker و Docker Compose با موفقیت نصب شدند."
}

########################################
# 7) پیکربندی فایروال (UFW)
########################################
configure_ufw() {
  log "=== مرحله ۷: پیکربندی فایروال UFW ==="
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow http
  ufw allow https
  ufw allow 81/tcp  comment 'Nginx Proxy Manager Admin'
  ufw allow 9443/tcp comment 'Portainer Agent'
  ufw allow "${CODE_SERVER_PORT}/tcp" comment 'code-server (Public)'
  
  if [[ -n "$POSTGRES_REMOTE_IP" ]]; then
    log "باز کردن پورت PostgreSQL (${POSTGRES_PORT}) فقط برای IP: ${POSTGRES_REMOTE_IP}"
    ufw allow from "${POSTGRES_REMOTE_IP}" to any port "${POSTGRES_PORT}" proto tcp comment 'Remote PostgreSQL Access'
  fi
  
  ufw --force enable
  ok "فایروال UFW فعال و پیکربندی شد."
}

########################################
# 8) ایجاد و اجرای Docker Stack
########################################
setup_docker_stack() {
  log "=== مرحله ۸: ایجاد فایل‌های Docker Stack ==="
  mkdir -p /opt/stack/{metabase,npm-data,portainer-data}
  
  # الیسا: .env فایل برای مدیریت متغیرهای حساس
  cat > /opt/stack/.env <<EOF
# --- General Config ---
TIMEZONE=${TIMEZONE}

# --- Metabase Database Connection ---
# Metabase will connect to the host's PostgreSQL via this gateway
MB_DB_TYPE=postgres
MB_DB_NAME=${MB_DB_NAME}
MB_DB_USER=${MB_DB_USER}
MB_DB_PASSWORD=${MB_DB_PASSWORD}
MB_DB_HOST=pg-gateway
MB_DB_PORT=5432

# --- Host PostgreSQL Port for Gateway ---
HOST_POSTGRES_PORT=${POSTGRES_PORT}
EOF
  chmod 600 /opt/stack/.env

  cat > /opt/stack/docker-compose.yml <<'YAML'
# الیسا: فایل docker-compose برای مدیریت سرویس‌های داکری
# نسخه: 2.0
version: '3.8'

services:
  # این سرویس یک Gateway برای اتصال کانتینرها به سرویس PostgreSQL روی هاست است
  pg-gateway:
    image: alpine/socat:1.7-r6
    command: tcp-listen:5432,fork,reuseaddr tcp-connect:host.docker.internal:${HOST_POSTGRES_PORT}
    restart: unless-stopped
    networks:
      - backend
    extra_hosts:
      - "host.docker.internal:host-gateway"

  metabase:
    image: metabase/metabase:latest
    restart: unless-stopped
    environment:
      # متغیرها از فایل .env خوانده می‌شوند
      - TZ=${TIMEZONE}
      - MB_DB_TYPE=${MB_DB_TYPE}
      - MB_DB_DBNAME=${MB_DB_NAME}
      - MB_DB_PORT=${MB_DB_PORT}
      - MB_DB_USER=${MB_DB_USER}
      - MB_DB_PASS=${MB_DB_PASSWORD}
      - MB_DB_HOST=${MB_DB_HOST}
    depends_on:
      - pg-gateway
    networks:
      - backend

  npm:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./npm-data:/data
      - ./npm-data/letsencrypt:/etc/letsencrypt
    networks:
      - backend
    # الیسا: این بخش به NPM اجازه می‌دهد سرویس‌های روی هاست (مثل pgAdmin) را پروکسی کند
    extra_hosts:
      - "host.docker.internal:host-gateway"

  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - '9443:9443'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer-data:/data
    networks:
      - backend

networks:
  backend:
    driver: bridge
YAML

  ok "فایل‌های Docker Compose در /opt/stack ایجاد شدند."
  
  log "بالا آوردن Docker Stack (ممکن است کمی طول بکشد)..."
  cd /opt/stack
  docker compose pull
  docker compose up -d
  ok "Docker Stack با موفقیت اجرا شد."
}

########################################
# 9) خلاصه نهایی
########################################
print_summary() {
  local SERVER_IP
  SERVER_IP=$(curl -s ifconfig.me)
  
  local REMOTE_DB_INFO=""
  if [[ -n "$POSTGRES_REMOTE_IP" ]]; then
    REMOTE_DB_INFO="
  - دسترسی ریموت: فعال
    - IP مجاز: ${POSTGRES_REMOTE_IP}
    - Connection String: postgresql://${POSTGRES_USER}:PASSWORD@${SERVER_IP}:${POSTGRES_PORT}/${POSTGRES_DB}
"
  else
    REMOTE_DB_INFO="
  - دسترسی ریموت: غیرفعال (فقط لوکال)
"
  fi
  
  local SUM="
============================== خلاصه نهایی نصب ==============================
سرور شما با موفقیت پیکربندی شد. IP عمومی سرور: ${SERVER_IP}

--- 🛡️ دسترسی‌های عمومی (تحت مدیریت فایروال) ---
- Nginx Proxy Manager (Admin): http://${SERVER_IP}:81
- Portainer (Docker UI):       https://${SERVER_IP}:9443 (Self-signed cert)
- code-server (Web IDE):       http://${SERVER_IP}:${CODE_SERVER_PORT}
  - کاربر: root
  - پسورد: (محرمانه‌ای که وارد کردید)

--- 📦 سرویس‌های داخلی (برای پروکسی شدن توسط NPM) ---
- Metabase: در شبکه داخلی داکر روی پورت 3000 اجرا می‌شود.
- pgAdmin: روی هاست و آدرس 127.0.0.1:${PGADMIN_PORT} اجرا می‌شود.

--- 🐘 PostgreSQL 17 (نصب شده روی هاست) ---
  - پورت: ${POSTGRES_PORT}
  - کاربر ادمین: ${POSTGRES_USER}
  - پسورد ادمین: (محرمانه‌ای که وارد کردید)
  - دیتابیس اصلی: ${POSTGRES_DB}${REMOTE_DB_INFO}

--- 🔑 اطلاعات دیتابیس Metabase (Metadata) ---
  - دیتابیس: ${MB_DB_NAME}
  - کاربر: ${MB_DB_USER}
  - پسورد: (محرمانه‌ای که وارد کردید)

--- 🚀 مراحل بعدی پیشنهادی (Action Items) ---
1.  به پنل Nginx Proxy Manager (http://${SERVER_IP}:81) بروید.
    - ایمیل پیش‌فرض: admin@example.com
    - پسورد پیش‌فرض: changeme
2.  برای سرویس‌های زیر Proxy Host ایجاد کنید:
    - **pgAdmin:**
      - Domain: pgadmin.your-domain.com
      - Scheme: http
      - Forward Hostname/IP: host.docker.internal
      - Forward Port: ${PGADMIN_PORT}
      - فعال کردن SSL (Let's Encrypt) و Force SSL.
    - **Metabase:**
      - Domain: metabase.your-domain.com
      - Scheme: http
      - Forward Hostname/IP: metabase
      - Forward Port: 3000
      - فعال کردن SSL (Let's Encrypt) و Force SSL.
    - **code-server:**
      - Domain: ide.your-domain.com
      - Scheme: http
      - Forward Hostname/IP: host.docker.internal
      - Forward Port: ${CODE_SERVER_PORT}
      - در تب Advanced، این کد را اضافه کنید تا WebSocket به درستی کار کند:
        location / {
            proxy_pass http://host.docker.internal:${CODE_SERVER_PORT};
            proxy_set_header Host \$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection upgrade;
            proxy_set_header Accept-Encoding gzip;
        }
================================================================================
"
  echo -e "$SUM"
  write_summary "$SUM"
}

########################################
# MAIN
########################################
main() {
  local start_time
  start_time=$(date +%s)
  
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
  print_summary
  
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  log "نصب کامل شد! مدت زمان کل: $((duration / 60)) دقیقه و $((duration % 60)) ثانیه."
}

main "$@"
