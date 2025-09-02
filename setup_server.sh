#!/usr/bin/env bash
# =============================================================================
#  setup_server.sh  —  Ubuntu 22.04 LTS
#  Stack: Python 3.10, PostgreSQL 14 (public), code-server (public, root),
#         Nginx Proxy Manager & Portainer via Docker, UFW rules
#  Idempotent: safe to re-run
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

prompt_value() { local q="$1" def="${2-}" ans=""; if [[ -n "$def" ]]; then read -r -p "$q [$def]: " ans || true; ans="${ans:-$def}"; else read -r -p "$q: " ans || true; while [[ -z "$ans" ]]; do read -r -p "$q (خالی نباشد): " ans || true; done; fi; echo "$ans"; }
prompt_secret(){ local q="$1" a1="" a2=""; while true; do read -r -s -p "$q (مخفی): " a1 || true; echo; [[ -n "$a1" ]] || { echo " - خالی نباشد."; continue; }; read -r -s -p "تکرار $q: " a2 || true; echo; if [[ "$a1" == "$a2" ]]; then echo "$a1"; return 0; else echo " - مطابقت ندارند؛ دوباره."; fi; done; }
write_summary(){ local f="/root/setup_summary.txt"; umask 077; printf "%s\n" "$1" > "$f"; chmod 600 "$f"; echo "📄 خلاصه در: $f"; }

########################################
# 0) Inputs
########################################
gather_inputs() {
  echo "=== پیکربندی تعاملی ==="
  TIMEZONE=$(prompt_value "Timezone" "Etc/UTC")
  CODE_SERVER_PORT="8443"   # طبق خواستهٔ شما ثابت
  POSTGRES_PORT="5432"      # پیش‌فرض PostgreSQL
  POSTGRES_PASSWORD=$(prompt_secret "پسورد کاربر postgres (برای اتصال از نت)")
  CODE_SERVER_PASSWORD=$(prompt_secret "پسورد ورود به code-server (PUBLIC)")
  ok "ورودی‌ها دریافت شد."
}

########################################
# 1) System prep & base packages
########################################
prepare_system() {
  log "System update/upgrade + base tools"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y dist-upgrade -qq
  apt-get -y autoremove -qq
  timedatectl set-timezone "$TIMEZONE" || true
  apt-get install -y apt-transport-https ca-certificates curl gnupg unzip zip git nano tmux ufw software-properties-common lsb-release -qq
  local hn; hn="$(hostname)"; grep -q "127.0.1.1.*${hn}" /etc/hosts || echo "127.0.1.1 ${hn} ${hn%%.*}" >> /etc/hosts
  ok "System ready."
}

########################################
# 2) Python 3.10
########################################
install_python_310() {
  log "Installing Python 3.10"
  apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip -qq
  update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
  python3 -m pip -q install --upgrade pip
  ok "Python 3.10 installed and set default."
}

########################################
# 3) PostgreSQL 14 (public 0.0.0.0, SCRAM, no DB creation)
########################################
install_postgresql14() {
  log "Installing PostgreSQL 14 (Ubuntu repo)"
  apt-get update -qq
  apt-get install -y postgresql postgresql-contrib postgresql-client -qq

  # Detect major (should be 14)
  local PG_MAJ="14"
  command -v pg_lsclusters >/dev/null 2>&1 && PG_MAJ="$(pg_lsclusters -h | awk 'NR==1{print $1}')" || true
  [[ -z "$PG_MAJ" ]] && PG_MAJ="14"

  local CONF_DIR="/etc/postgresql/${PG_MAJ}/main"
  local PG_CONF="${CONF_DIR}/postgresql.conf"
  local PG_HBA="${CONF_DIR}/pg_hba.conf"

  [[ -d "$CONF_DIR" ]] || { err "Config dir not found: $CONF_DIR"; exit 1; }

  # Bind & port
  grep -qE '^\s*#?\s*listen_addresses' "$PG_CONF" \
    && sed -i "s/^#\?listen_addresses.*/listen_addresses = '0.0.0.0'/" "$PG_CONF" \
    || echo "listen_addresses = '0.0.0.0'" >> "$PG_CONF"

  grep -qE '^\s*#?\s*port\s*=' "$PG_CONF" \
    && sed -i "s/^#\?port.*/port = ${POSTGRES_PORT}/" "$PG_CONF" \
    || echo "port = ${POSTGRES_PORT}" >> "$PG_CONF"

  # Ensure SCRAM
  grep -qE '^\s*#?\s*password_encryption' "$PG_CONF" \
    && sed -i "s/^#\?password_encryption.*/password_encryption = 'scram-sha-256'/" "$PG_CONF" \
    || echo "password_encryption = 'scram-sha-256'" >> "$PG_CONF"

  # pg_hba: allow all with SCRAM (explicit request)
  if ! grep -qE '^\s*host\s+all\s+all\s+0\.0\.0\.0/0\s+scram-sha-256' "$PG_HBA"; then
    echo "host    all             all             0.0.0.0/0            scram-sha-256" >> "$PG_HBA"
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl restart postgresql || true
  command -v pg_ctlcluster >/dev/null 2>&1 && pg_ctlcluster "$PG_MAJ" main start || true

  # Set password for postgres (safe quoting via DO $$)
  cat <<'SQL' | sudo -H -u postgres psql -v ON_ERROR_STOP=1 -v pw="${POSTGRES_PASSWORD}"
DO $$
BEGIN
  EXECUTE 'ALTER ROLE postgres PASSWORD ' || quote_literal(:'pw');
END
$$;
SQL

  ok "PostgreSQL ${PG_MAJ} listening on 0.0.0.0:${POSTGRES_PORT} (SCRAM, postgres password set)."
}

########################################
# 4) code-server (PUBLIC, root, port 8443)
########################################
install_codeserver() {
  log "Installing code-server (PUBLIC) on 0.0.0.0:8443"
  curl -fsSL https://code-server.dev/install.sh | sh
  umask 077
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: "${CODE_SERVER_PASSWORD}"
cert: false
EOF

  # Own systemd unit (explicit root)
  cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server (root)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/code-server
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now code-server
  systemctl restart code-server
  ok "code-server is up at 0.0.0.0:${CODE_SERVER_PORT}"
}

########################################
# 5) Docker & Compose
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
  ok "Docker ready."
}

########################################
# 6) Docker stack: NPM + Portainer
########################################
setup_docker_stack() {
  log "Writing docker-compose stack (NPM + Portainer)"
  mkdir -p /opt/stack/npm /opt/stack/portainer
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
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt

  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer/data:/data
YAML

  ( cd /opt/stack && docker compose pull && docker compose up -d )
  ok "NPM (80/81/443) & Portainer (9443) are up."
}

########################################
# 7) UFW firewall
########################################
configure_ufw() {
  log "Configuring UFW (public ports)"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH || ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 81/tcp
  ufw allow 443/tcp
  ufw allow 9443/tcp
  ufw allow ${CODE_SERVER_PORT}/tcp
  ufw allow ${POSTGRES_PORT}/tcp   # explicit request: open to the world
  ufw --force enable
  ok "UFW enabled."
}

########################################
# 8) Sanity checks + Summary
########################################
sanity_and_summary() {
  local ip; ip="$(curl -s ifconfig.me || echo 'YOUR_SERVER_IP')"

  echo -e "\n==== LISTEN PORTS ===="
  ss -ltnp | egrep "(:80|:81|:443|:9443|:${CODE_SERVER_PORT}|:${POSTGRES_PORT})\b" || true

  echo -e "\n==== LOCAL CURL TESTS ===="
  for u in "http://127.0.0.1:81" "http://127.0.0.1:80" "https://127.0.0.1:9443" "http://127.0.0.1:${CODE_SERVER_PORT}"; do
    echo -n "$u -> "; curl -skI --max-time 5 "$u" | head -n1 || echo "FAIL"
  done

  echo -e "\n==== DOCKER COMPOSE PS ===="
  (cd /opt/stack && docker compose ps) || true

  local SUMMARY="
==================== خلاصهٔ نصب ====================
[عمومی]
- Nginx Proxy Manager (Admin):  http://${ip}:81   (defaults: admin@example.com / changeme)
- Portainer:                    https://${ip}:9443
- code-server (root):           http://${ip}:${CODE_SERVER_PORT}
  * Password: ${CODE_SERVER_PASSWORD}

[PostgreSQL 14]
- Bind: 0.0.0.0:${POSTGRES_PORT}
- User: postgres
- Password: (همانی که وارد کردی)
- احراز هویت شبکه: SCRAM برای 0.0.0.0/0 (هشدار: کاملاً پابلیک)

[Firewall/UFW]
- Open: 22, 80, 81, 443, 9443, ${CODE_SERVER_PORT}, ${POSTGRES_PORT}
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
  install_python_310
  install_postgresql14
  install_codeserver
  install_docker
  setup_docker_stack
  configure_ufw
  sanity_and_summary
  ok "تمام شد."
}

main "$@"
