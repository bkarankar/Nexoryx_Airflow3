#!/usr/bin/env bash
set -euo pipefail

# Created by Bhupesh Karankar 
# Apache Airflow 3.2.1 automated install for fresh Ubuntu 24.04 EC2 - v3
# Stack: Airflow + PostgreSQL + Redis/CeleryExecutor + Nginx + HTTPS + Azure Entra ID SSO + API DAG trigger user
#
# Run as root:
#   sudo bash install_airflow3_ec2.sh
#
# Before running:
#   1. Point DNS A record for AIRFLOW_DOMAIN to this EC2 public IP.
#   2. In Azure App Registration, set redirect URI:
#      https://${AIRFLOW_DOMAIN}/auth/oauth-authorized/azure
#   3. Review variables below.

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

cleanup() {
  rm -f /usr/sbin/policy-rc.d 2>/dev/null || true
}
trap cleanup EXIT

AIRFLOW_DOMAIN="${AIRFLOW_DOMAIN:-airflow.devops.karankar.com}"
AIRFLOW_VERSION="${AIRFLOW_VERSION:-3.2.1}"
AIRFLOW_USER="${AIRFLOW_USER:-airflow}"
AIRFLOW_HOME="${AIRFLOW_HOME:-/opt/airflow}"

POSTGRES_DB="${POSTGRES_DB:-airflow}"
POSTGRES_USER="${POSTGRES_USER:-airflow}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-REPLACE_ME}"

REDIS_PASSWORD="${REDIS_PASSWORD:-REPLACE_ME}"

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-CHANGE_ME}"
ADMIN_EMAIL="${ADMIN_EMAIL:-devops@karankar.com}"

API_USERNAME="${API_USERNAME:-api_user}"
API_PASSWORD="${API_PASSWORD:-CHANGE_ME}"
API_EMAIL="${API_EMAIL:-devops1@karankar.com}"

AZURE_TENANT_ID="${AZURE_TENANT_ID:-13d8c6f3-3233-4026-80d5-02df2e207adb}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-c37a422a-031e-4a91-a199-2ff4324295b6}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-s918K~BKtHUmjfYDWFUMuH_TEI.Kq~vyVJeCsaRB}"

CERTBOT_EMAIL="${CERTBOT_EMAIL:-devops@karankar.com}"
ENABLE_CERTBOT="${ENABLE_CERTBOT:-true}"

log() {
  echo
  echo "==== $* ===="
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root or with sudo."
  fi
}

check_ubuntu() {
  log "Checking OS"
  . /etc/os-release
  echo "Detected: ${PRETTY_NAME}"
  if [[ "${ID}" != "ubuntu" ]]; then
    fail "This script is intended for Ubuntu."
  fi
  if [[ "${VERSION_ID}" != "24.04" ]]; then
    echo "WARNING: Expected Ubuntu 24.04, detected ${VERSION_ID}. Continuing because python3 constraints are dynamic."
  fi
}

install_packages() {
  log "Installing OS packages safely"

  # On EC2 instances with IPv6 disabled, nginx post-install can fail while trying to bind [::]:80.
  # Prevent services from auto-starting during apt install, then fix nginx IPv6 listeners before starting it.
  cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod +x /usr/sbin/policy-rc.d

  apt-get update
  apt-get ${APT_OPTS} upgrade
  apt-get ${APT_OPTS} install \
    python3 python3-venv python3-pip python3-dev \
    build-essential libssl-dev libffi-dev \
    libpq-dev postgresql postgresql-contrib \
    redis-server nginx certbot python3-certbot-nginx \
    curl vim git software-properties-common dnsutils jq ca-certificates

  rm -f /usr/sbin/policy-rc.d

  # If any package was left half-configured, fix nginx IPv6 first, then finish dpkg.
  fix_nginx_ipv6_config_only
  dpkg --configure -a
}

fix_nginx_ipv6_config_only() {
  log "Fixing Nginx IPv6 listeners in config only"
  cp -a /etc/nginx "/etc/nginx.backup.$(date +%F-%H%M%S)" 2>/dev/null || true
  sed -i 's/^[[:space:]]*listen \[::\]:80/# listen [::]:80/' /etc/nginx/sites-available/default 2>/dev/null || true
  sed -i 's/^[[:space:]]*listen \[::\]:443/# listen [::]:443/' /etc/nginx/sites-available/default 2>/dev/null || true
  sed -i 's/^[[:space:]]*listen \[::\]:80/# listen [::]:80/' /etc/nginx/sites-enabled/* 2>/dev/null || true
  sed -i 's/^[[:space:]]*listen \[::\]:443/# listen [::]:443/' /etc/nginx/sites-enabled/* 2>/dev/null || true
}

fix_nginx_ipv6() {
  log "Disabling Nginx IPv6 listeners if IPv6 is unavailable"
  fix_nginx_ipv6_config_only
  nginx -t
  systemctl enable nginx || true
  systemctl restart nginx
}

create_airflow_user_dirs() {
  log "Creating airflow user and directories"
  useradd --system --create-home --home-dir "${AIRFLOW_HOME}" --shell /bin/bash "${AIRFLOW_USER}" 2>/dev/null || true
  mkdir -p "${AIRFLOW_HOME}"/{dags,logs,plugins}
  chown -R "${AIRFLOW_USER}:${AIRFLOW_USER}" "${AIRFLOW_HOME}"
}

configure_postgres() {
  log "Configuring PostgreSQL"
  systemctl enable --now postgresql

  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
      CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
   ELSE
      ALTER USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
   END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}')\gexec
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_USER};
SQL
}

configure_redis() {
  log "Configuring Redis"
  cp -a /etc/redis/redis.conf "/etc/redis/redis.conf.backup.$(date +%F-%H%M%S)" || true

  sed -i 's/^# *supervised .*/supervised systemd/' /etc/redis/redis.conf
  sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf
  sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
  sed -i 's/^protected-mode .*/protected-mode yes/' /etc/redis/redis.conf

  if grep -q '^requirepass ' /etc/redis/redis.conf; then
    sed -i "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" /etc/redis/redis.conf
  else
    echo "requirepass ${REDIS_PASSWORD}" >> /etc/redis/redis.conf
  fi

  systemctl enable --now redis-server
  systemctl restart redis-server
  redis-cli -a "${REDIS_PASSWORD}" ping | grep -q PONG
}

install_airflow() {
  log "Installing Apache Airflow ${AIRFLOW_VERSION}"
  sudo -u "${AIRFLOW_USER}" bash -lc "
    set -euo pipefail
    cd '${AIRFLOW_HOME}'
    python3 -m venv venv
    source '${AIRFLOW_HOME}/venv/bin/activate'
    python -m pip install --upgrade pip setuptools wheel
    pip install pandas
    PYTHON_VERSION=\$(python -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')
    CONSTRAINT_URL='https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-'\${PYTHON_VERSION}'.txt'
    pip install 'apache-airflow[celery,postgres,redis]==${AIRFLOW_VERSION}' --constraint \"\${CONSTRAINT_URL}\"
    pip install apache-airflow-providers-fab authlib
    airflow version
    pip check
  "
}

generate_secrets_and_env() {
  log "Generating Airflow secrets and writing /etc/airflow.env"
  local pg_encoded redis_encoded fernet secret jwt
  pg_encoded="$(urlencode "${POSTGRES_PASSWORD}")"
  redis_encoded="$(urlencode "${REDIS_PASSWORD}")"

  read -r fernet secret jwt < <(sudo -u "${AIRFLOW_USER}" bash -lc "
    source '${AIRFLOW_HOME}/venv/bin/activate'
    python - <<'PY'
from cryptography.fernet import Fernet
import secrets
print(Fernet.generate_key().decode(), secrets.token_urlsafe(48), secrets.token_urlsafe(48))
PY
  ")

  cat >/etc/airflow.env <<EOF
AIRFLOW_HOME=${AIRFLOW_HOME}

AIRFLOW__CORE__EXECUTOR=CeleryExecutor
AIRFLOW__CORE__LOAD_EXAMPLES=False
AIRFLOW__CORE__FERNET_KEY=${fernet}

# Airflow 3 auth manager. Config reference shows this under [core].
AIRFLOW__CORE__AUTH_MANAGER=airflow.providers.fab.auth_manager.fab_auth_manager.FabAuthManager
AIRFLOW__API__AUTH_BACKENDS=airflow.providers.fab.auth_manager.api.auth.backend.basic_auth,airflow.providers.fab.auth_manager.api.auth.backend.session

AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${POSTGRES_USER}:${pg_encoded}@127.0.0.1:5432/${POSTGRES_DB}

# Airflow 3 API/UI URL
AIRFLOW__API__BASE_URL=https://${AIRFLOW_DOMAIN}
AIRFLOW__CORE__EXECUTION_API_SERVER_URL=https://${AIRFLOW_DOMAIN}/execution/
AIRFLOW__API__HOST=127.0.0.1
AIRFLOW__API__PORT=8080
AIRFLOW__WEBSERVER__BASE_URL=https://${AIRFLOW_DOMAIN}
AIRFLOW__WEBSERVER__ENABLE_PROXY_FIX=True

AIRFLOW__API__SECRET_KEY=${secret}

# JWT secret for API auth internals
AIRFLOW__API_AUTH__JWT_SECRET=${jwt}

# Celery with Redis broker and database-backed result backend.
AIRFLOW__CELERY__BROKER_URL=redis://:${redis_encoded}@127.0.0.1:6379/0
AIRFLOW__CELERY__RESULT_BACKEND=db+postgresql://${POSTGRES_USER}:${pg_encoded}@127.0.0.1:5432/${POSTGRES_DB}

# Logging
AIRFLOW__LOGGING__BASE_LOG_FOLDER=${AIRFLOW_HOME}/logs
AIRFLOW__LOGGING__DAG_PROCESSOR_MANAGER_LOG_LOCATION=${AIRFLOW_HOME}/logs/dag_processor_manager/dag_processor_manager.log

# Timezone
AIRFLOW__CORE__DEFAULT_TIMEZONE=Asia/Kolkata
AZURE_TENANT_ID="${AZURE_TENANT_ID}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET}"
EOF

  chown root:"${AIRFLOW_USER}" /etc/airflow.env
  chmod 640 /etc/airflow.env
}

write_webserver_config() {
  log "Writing Azure SSO webserver_config.py"
  cat >"${AIRFLOW_HOME}/webserver_config.py" <<'PY'
import base64
import json
import logging
import os

from flask_appbuilder.security.manager import AUTH_OAUTH
from airflow.providers.fab.auth_manager.security_manager.override import FabAirflowSecurityManagerOverride

log = logging.getLogger(__name__)

ENABLE_PROXY_FIX = True
PROXY_FIX_X_FOR = 1
PROXY_FIX_X_PROTO = 1
PROXY_FIX_X_HOST = 1
PROXY_FIX_X_PORT = 1
PREFERRED_URL_SCHEME = "https"
SESSION_COOKIE_SECURE = True

AUTH_TYPE = AUTH_OAUTH
AUTH_USER_REGISTRATION = True
AUTH_USER_REGISTRATION_ROLE = "Viewer"
AUTH_ROLES_SYNC_AT_LOGIN = True
AUTH_ROLES_MAPPING = {
    "Admin": ["Admin"],
    "User": ["User"],
    "Viewer": ["Viewer"],
}

TENANT_ID = os.environ.get("AZURE_TENANT_ID", "")
CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("AZURE_CLIENT_SECRET", "")

if not TENANT_ID:
    raise RuntimeError("AZURE_TENANT_ID is missing from environment")
if not CLIENT_ID:
    raise RuntimeError("AZURE_CLIENT_ID is missing from environment")
if not CLIENT_SECRET:
    raise RuntimeError("AZURE_CLIENT_SECRET is missing from environment")


def _decode_jwt_no_verify(token):
    if not token:
        return {}
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        decoded = base64.urlsafe_b64decode(payload.encode()).decode()
        return json.loads(decoded)
    except Exception as exc:
        log.exception("Failed to decode Azure JWT payload: %s", exc)
        return {}


class AzureCustomSecurityManager(FabAirflowSecurityManagerOverride):
    def get_oauth_user_info(self, provider, response=None):
        if provider != "azure":
            return super().get_oauth_user_info(provider, response)

        response = response or {}
        id_token_claims = _decode_jwt_no_verify(response.get("id_token"))
        access_token_claims = _decode_jwt_no_verify(response.get("access_token"))

        claims = {}
        claims.update(access_token_claims)
        claims.update(id_token_claims)

        email = (
            claims.get("email")
            or claims.get("preferred_username")
            or claims.get("upn")
            or claims.get("unique_name")
        )

        if not email:
            log.error("Azure OAuth login failed. No usable email claim found. Claims=%s", claims)
            return {}

        email = email.lower()
        name = claims.get("name") or email
        first_name = claims.get("given_name") or email.split("@")[0]
        last_name = claims.get("family_name") or "User"
        role_keys = claims.get("roles") or ["Viewer"]

        return {
            "username": email,
            "email": email,
            "first_name": first_name,
            "last_name": last_name,
            "name": name,
            "role_keys": role_keys,
        }


SECURITY_MANAGER_CLASS = AzureCustomSecurityManager
FAB_SECURITY_MANAGER_CLASS = AzureCustomSecurityManager

OAUTH_PROVIDERS = [
    {
        "name": "azure",
        "icon": "fa-windows",
        "token_key": "access_token",
        "remote_app": {
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "server_metadata_url": f"https://login.microsoftonline.com/{TENANT_ID}/v2.0/.well-known/openid-configuration",
            "api_base_url": "https://graph.microsoft.com/oidc/userinfo",
            "client_kwargs": {
                "scope": "openid email profile User.Read",
            },
            "request_token_url": None,
            "access_token_url": f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token",
            "authorize_url": f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/authorize",
        },
    }
]
PY
  chown "${AIRFLOW_USER}:${AIRFLOW_USER}" "${AIRFLOW_HOME}/webserver_config.py"
  chmod 600 "${AIRFLOW_HOME}/webserver_config.py"
  sudo -u "${AIRFLOW_USER}" bash -lc "
    source '${AIRFLOW_HOME}/venv/bin/activate'
    python -m py_compile '${AIRFLOW_HOME}/webserver_config.py'
  "
}

init_airflow_db_users() {
  log "Initializing Airflow database and users"
  sudo -u "${AIRFLOW_USER}" bash -lc "
    set -euo pipefail
    cd '${AIRFLOW_HOME}'
    source '${AIRFLOW_HOME}/venv/bin/activate'
    set -a
    source /etc/airflow.env
    set +a
    airflow db migrate
    airflow fab-db migrate
    airflow users create --username '${ADMIN_USERNAME}' --firstname Airflow --lastname Admin --role Admin --email '${ADMIN_EMAIL}' --password '${ADMIN_PASSWORD}' || true
    airflow users create --username '${API_USERNAME}' --firstname API --lastname User --role Admin --email '${API_EMAIL}' --password '${API_PASSWORD}' || true
    airflow users list
  "
}

write_systemd_services() {
  log "Writing systemd services"
  cat >/etc/systemd/system/airflow-api-server.service <<EOF
[Unit]
Description=Apache Airflow API Server
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
EnvironmentFile=/etc/airflow.env
Environment="AIRFLOW__CORE__AUTH_MANAGER=airflow.providers.fab.auth_manager.fab_auth_manager.FabAuthManager"
Environment="AIRFLOW__API__AUTH_BACKENDS=airflow.providers.fab.auth_manager.api.auth.backend.basic_auth,airflow.providers.fab.auth_manager.api.auth.backend.session"
Environment="FORWARDED_ALLOW_IPS=127.0.0.1"
User=${AIRFLOW_USER}
Group=${AIRFLOW_USER}
WorkingDirectory=${AIRFLOW_HOME}
ExecStart=/usr/bin/env AIRFLOW__CORE__AUTH_MANAGER=airflow.providers.fab.auth_manager.fab_auth_manager.FabAuthManager AIRFLOW__API__AUTH_BACKENDS=airflow.providers.fab.auth_manager.api.auth.backend.basic_auth,airflow.providers.fab.auth_manager.api.auth.backend.session FORWARDED_ALLOW_IPS=127.0.0.1 ${AIRFLOW_HOME}/venv/bin/airflow api-server --proxy-headers
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/airflow-scheduler.service <<EOF
[Unit]
Description=Apache Airflow Scheduler
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
EnvironmentFile=/etc/airflow.env
User=${AIRFLOW_USER}
Group=${AIRFLOW_USER}
WorkingDirectory=${AIRFLOW_HOME}
ExecStart=${AIRFLOW_HOME}/venv/bin/airflow scheduler
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/airflow-dag-processor.service <<EOF
[Unit]
Description=Apache Airflow DAG Processor
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
EnvironmentFile=/etc/airflow.env
User=${AIRFLOW_USER}
Group=${AIRFLOW_USER}
WorkingDirectory=${AIRFLOW_HOME}
ExecStart=${AIRFLOW_HOME}/venv/bin/airflow dag-processor
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/airflow-triggerer.service <<EOF
[Unit]
Description=Apache Airflow Triggerer
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
EnvironmentFile=/etc/airflow.env
User=${AIRFLOW_USER}
Group=${AIRFLOW_USER}
WorkingDirectory=${AIRFLOW_HOME}
ExecStart=${AIRFLOW_HOME}/venv/bin/airflow triggerer
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/airflow-worker.service <<EOF
[Unit]
Description=Apache Airflow Celery Worker
After=network.target postgresql.service redis-server.service airflow-api-server.service
Wants=postgresql.service redis-server.service airflow-api-server.service

[Service]
EnvironmentFile=/etc/airflow.env
User=${AIRFLOW_USER}
Group=${AIRFLOW_USER}
WorkingDirectory=${AIRFLOW_HOME}
ExecStart=${AIRFLOW_HOME}/venv/bin/airflow celery worker
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer airflow-worker
}

configure_nginx() {
  log "Configuring Nginx reverse proxy"
  rm -f /etc/nginx/sites-enabled/default || true

  cat >/etc/nginx/sites-available/airflow <<EOF
server {
    listen 80;
    server_name ${AIRFLOW_DOMAIN};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 80;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF

  ln -s /etc/nginx/sites-available/airflow /etc/nginx/sites-enabled/airflow 2>/dev/null || true
  nginx -t
  systemctl reload nginx
}

enable_https_if_ready() {
  if [[ "${ENABLE_CERTBOT}" != "true" ]]; then
    log "Skipping Certbot because ENABLE_CERTBOT=${ENABLE_CERTBOT}"
    return
  fi

  log "Checking DNS before Certbot"
  local public_ip dns_ip
  imds_token="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)"
  if [[ -n "${imds_token}" ]]; then
    public_ip="$(curl -fsS -H "X-aws-ec2-metadata-token: ${imds_token}" http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  else
    public_ip="$(curl -fsS http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  fi
  dns_ip="$(dig +short "${AIRFLOW_DOMAIN}" A | tail -1 || true)"

  echo "EC2 public IP: ${public_ip:-unknown}"
  echo "DNS A record: ${dns_ip:-missing}"

  if [[ -z "${dns_ip}" ]]; then
    echo "Skipping Certbot: DNS A record not found for ${AIRFLOW_DOMAIN}."
    return
  fi

  if [[ -n "${public_ip}" && "${dns_ip}" != "${public_ip}" ]]; then
    echo "Skipping Certbot: DNS does not point to this EC2 public IP."
    return
  fi

  certbot --nginx -d "${AIRFLOW_DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" --redirect

  cat >/etc/nginx/sites-available/airflow <<EOF
server {
    server_name ${AIRFLOW_DOMAIN};
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/${AIRFLOW_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${AIRFLOW_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if (\$host = ${AIRFLOW_DOMAIN}) {
        return 301 https://\$host\$request_uri;
    }

    listen 80;
    server_name ${AIRFLOW_DOMAIN};
    return 404;
}
EOF

  nginx -t
  systemctl reload nginx
}

write_dummy_dag() {
  log "Writing dummy API DAG"
  cat >"${AIRFLOW_HOME}/dags/dummy_api_dag.py" <<'PY'
from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime


def hello():
    print("Hello from API triggered DAG")


with DAG(
    dag_id="dummy_api_dag",
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False,
    tags=["api-test"],
) as dag:
    hello_task = PythonOperator(
        task_id="hello_task",
        python_callable=hello,
    )
PY
  chown "${AIRFLOW_USER}:${AIRFLOW_USER}" "${AIRFLOW_HOME}/dags/dummy_api_dag.py"
}

start_services() {
  log "Starting Airflow services"
  systemctl restart airflow-api-server airflow-scheduler airflow-dag-processor airflow-triggerer airflow-worker
  sleep 15
  systemctl --no-pager --full status airflow-api-server || true
  systemctl --no-pager --full status airflow-scheduler || true
  systemctl --no-pager --full status airflow-dag-processor || true
  systemctl --no-pager --full status airflow-triggerer || true
  systemctl --no-pager --full status airflow-worker || true
}

verify_and_trigger_dummy() {
  log "Verifying API token and dummy DAG trigger"
  local token
  token="$(curl -fsS -X POST "http://localhost:8080/auth/token" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${API_USERNAME}\",\"password\":\"${API_PASSWORD}\"}" | jq -r '.access_token')"

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    fail "Failed to get API token for ${API_USERNAME}."
  fi

  curl -fsS "http://localhost:8080/api/v2/dags" \
    -H "Authorization: Bearer ${token}" | jq

  curl -fsS -X PATCH "http://localhost:8080/api/v2/dags/dummy_api_dag" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"is_paused": false}' | jq

  cat >/tmp/dagrun.json <<EOF
{
  "logical_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "conf": {
    "source": "api_test"
  }
}
EOF

  curl -fsS -X POST "http://localhost:8080/api/v2/dags/dummy_api_dag/dagRuns" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/dagrun.json | jq
}

print_summary() {
  log "Installation complete"
  cat <<EOF
Airflow URL:
  https://${AIRFLOW_DOMAIN}

Local API:
  http://localhost:8080

Azure redirect URI required:
  https://${AIRFLOW_DOMAIN}/auth/oauth-authorized/azure

Local admin user:
  ${ADMIN_USERNAME} / ${ADMIN_PASSWORD}

API user:
  ${API_USERNAME} / ${API_PASSWORD}

Get token:
  TOKEN=\$(curl -s -X POST "http://localhost:8080/auth/token" -H "Content-Type: application/json" -d '{"username":"${API_USERNAME}","password":"${API_PASSWORD}"}' | jq -r '.access_token')

List DAGs:
  curl -s "http://localhost:8080/api/v2/dags" -H "Authorization: Bearer \$TOKEN" | jq

Trigger DAG:
  DAG_ID="dummy_api_dag"
  cat >/tmp/dagrun.json <<JSON
  {
    "logical_date": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "conf": {"source": "api"}
  }
JSON
  curl -X POST "http://localhost:8080/api/v2/dags/\${DAG_ID}/dagRuns" -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" --data-binary @/tmp/dagrun.json
EOF
}

main() {
  require_root
  check_ubuntu
  install_packages
  fix_nginx_ipv6
  create_airflow_user_dirs
  configure_postgres
  configure_redis
  install_airflow
  generate_secrets_and_env
  write_webserver_config
  init_airflow_db_users
  write_systemd_services
  configure_nginx
  enable_https_if_ready
  write_dummy_dag
  start_services
  verify_and_trigger_dummy
  print_summary
}

main "$@"
