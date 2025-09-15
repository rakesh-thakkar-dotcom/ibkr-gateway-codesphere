#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-10000}"
ZIP_URL="${IBKR_ZIP_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"

echo ">>> Render PORT: ${PORT}"
echo ">>> Fetching IBKR Client Portal Gateway from ${ZIP_URL} ..."

# Fetch the gateway zip
mkdir -p /tmp /home/app/ibgateway
curl -fsSL "${ZIP_URL}" -o /tmp/clientportal.gw.zip

echo ">>> Unzipping Gateway..."
unzip -q -o /tmp/clientportal.gw.zip -d /home/app/ibgateway

# The run script is in bin/ for current bundles
RUN_SH=""
if [ -f /home/app/ibgateway/bin/run.sh ]; then
  RUN_SH="/home/app/ibgateway/bin/run.sh"
elif [ -f /home/app/ibgateway/run.sh ]; then
  RUN_SH="/home/app/ibgateway/run.sh"
else
  echo "!! Couldn't find run.sh after unzip. Directory listing:"
  ls -la /home/app/ibgateway
  exit 1
fi

chmod +x "${RUN_SH}"

echo ">>> Starting IBKR Gateway (HTTPS on :5000)..."
cd /home/app/ibgateway
# Start the gateway in the background
"${RUN_SH}" >/home/app/gateway.log 2>&1 &
GW_PID=$!

echo ">>> Waiting for gateway to listen on :5000..."
for i in {1..60}; do
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

        # IBKR gateway uses its own cert; don't verify it here
        proxy_ssl_verify off;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;

        proxy_redirect off;
    }
}
EOF

# Make sure nginx can start cleanly
mkdir -p /var/lib/nginx/tmp /var/lib/nginx/body /run/nginx

echo ">>> Launching Nginx in the foreground..."
exec nginx -g 'daemon off;'

