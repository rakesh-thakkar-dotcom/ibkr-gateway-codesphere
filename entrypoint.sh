#!/usr/bin/env bash
set -euo pipefail

# --------- Config ----------
PORT="${PORT:-10000}"                  # Render passes this
GW_DIR="/home/app/ibgateway"
GW_ZIP="/tmp/clientportal.gw.zip"
ZIP_URL="${IBKR_ZIP_URL:-}"

echo ">>> Starting entrypoint"
echo ">>> Render PORT: ${PORT}"

# --------- Fetch Gateway ----------
if [[ -z "${ZIP_URL}" ]]; then
  echo "ERROR: IBKR_ZIP_URL env var is not set. Please set it in Render."
  exit 9
fi

echo ">>> Fetching IBKR Client Portal Gateway from ${ZIP_URL} ..."
curl -fsSL "${ZIP_URL}" -o "${GW_ZIP}"

rm -rf "${GW_DIR}"
mkdir -p "${GW_DIR}"

echo ">>> Unzipping Gateway..."
unzip -qo "${GW_ZIP}" -d "${GW_DIR}"
chmod +x "${GW_DIR}/run.sh"

# --------- Start Gateway (HTTPS on 5000) ----------
echo ">>> Starting IBKR Gateway (native HTTPS on :5000)..."
# Run in background so we can start Nginx
"${GW_DIR}/run.sh" root/conf.yaml &
GW_PID=$!

# Basic wait-for-5000 loop (TLS)
echo ">>> Waiting for gateway to accept HTTPS on :5000 ..."
for i in {1..60}; do
  if curl -skI "https://127.0.0.1:5000/" >/dev/null 2>&1; then
    echo ">>> Gateway is up on :5000"
    break
  fi
  sleep 1
  if ! kill -0 "${GW_PID}" 2>/dev/null; then
    echo "ERROR: Gateway process exited early."
    wait "${GW_PID}" || true
    exit 1
  fi
done

# --------- Write Nginx config that listens on $PORT and proxies to https://127.0.0.1:5000 ----------
echo ">>> Writing Nginx config for port ${PORT} -> https://127.0.0.1:5000 ..."
NGX_CONF="/tmp/ibkr-nginx.conf"
mkdir -p /tmp/nginx/{client_body,proxy,fastcgi,uwsgi,scgi}

cat > "${NGX_CONF}" <<EOF
events {}
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile      on;

  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  server {
    listen ${PORT};
    server_name _;

    # Proxy everything to the gateway's HTTPS on 5000
    location / {
      proxy_pass https://127.0.0.1:5000;
      proxy_ssl_verify off;                # gateway uses a self-signed cert
      proxy_set_header Host               \$host;
      proxy_set_header X-Forwarded-Proto  \$scheme;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header X-Real-IP          \$remote_addr;
    }
  }
}
EOF

echo ">>> Launching Nginx in the foreground on :${PORT} ..."
exec nginx -g 'daemon off;' -c "${NGX_CONF}"


