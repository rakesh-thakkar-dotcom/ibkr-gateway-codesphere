#!/usr/bin/env bash
set -euo pipefail

# Render passes the incoming HTTP port in $PORT
PORT="${PORT:-10000}"

# IBKR download URL (can be overridden via env if needed)
ZIP_URL="${IBKR_ZIP_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"
ZIP_PATH="/tmp/clientportal.gw.zip"
GW_DIR="/home/app/ibgateway"

echo ">>> Render PORT: ${PORT}"
echo ">>> Fetching IBKR Client Portal Gateway from: ${ZIP_URL}"

mkdir -p "$(dirname "${ZIP_PATH}")" "${GW_DIR}"

# Robust download with retries
# --retry-all-errors covers transient TLS/connectivity issues
# -f fail on HTTP errors, -S show errors, -L follow redirects, -s silent
if ! curl -fSLs --retry 10 --retry-delay 2 --retry-all-errors \
       -A "curl" \
       -o "${ZIP_PATH}" "${ZIP_URL}"; then
  echo "!! Failed to download gateway zip"
  exit 9
fi

# Sanity check: file exists and is not tiny
if [ ! -s "${ZIP_PATH}" ]; then
  echo "!! Downloaded zip is missing or empty"
  exit 9
fi

echo ">>> Unzipping Gateway..."
unzip -q -o "${ZIP_PATH}" -d "${GW_DIR}"

# Determine run.sh location
RUN_SH=""
if [ -f "${GW_DIR}/bin/run.sh" ]; then
  RUN_SH="${GW_DIR}/bin/run.sh"
elif [ -f "${GW_DIR}/run.sh" ]; then
  RUN_SH="${GW_DIR}/run.sh"
else
  echo "!! Couldn't find run.sh after unzip. Contents:"
  ls -la "${GW_DIR}"
  exit 1
fi
chmod +x "${RUN_SH}"

echo ">>> Starting IBKR Gateway (HTTPS on :5000)..."
cd "${GW_DIR}"
# Launch gateway in background
"${RUN_SH}" >/home/app/gateway.log 2>&1 &
GW_PID=$!

echo ">>> Waiting for gateway to listen on :5000..."
for i in {1..90}; do
  if curl -skI https://127.0.0.1:5000 >/dev/null 2>&1; then
    echo ">>> Gateway is up on :5000"
    break
  fi
  sleep 1
done

# Nginx reverse proxy: $PORT -> https://127.0.0.1:5000
echo ">>> Writing Nginx config (listen ${PORT} -> https://127.0.0.1:5000)..."
cat >/etc/nginx/conf.d/default.conf <<EOF
server {
    listen ${PORT};
    access_log off;
    error_log  /var/log/nginx/error.log warn;

    location / {
        proxy_pass https://127.0.0.1:5000;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Upstream is IBKR's self-signed TLS
        proxy_ssl_verify off;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;

        proxy_redirect off;
    }
}
EOF

# Ensure nginx has its temp/runtime dirs
mkdir -p /var/lib/nginx/tmp /var/lib/nginx/body /run/nginx

echo ">>> Launching Nginx in the foreground..."
exec nginx -g 'daemon off;'
