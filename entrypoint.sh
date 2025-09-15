#!/usr/bin/env bash
set -euo pipefail

DEST="/home/app/ibgateway"
ZIP="/tmp/clientportal.gw.zip"
URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Fetching IBKR Client Portal Gateway..."
mkdir -p "$DEST"
curl -fsSL -o "$ZIP" "$URL"
unzip -o "$ZIP" -d "$DEST"

echo ">>> Making run.sh executable..."
chmod +x "$DEST/bin/run.sh"

echo ">>> Starting IBKR Gateway (HTTPS on :5000)..."
(
  cd "$DEST"
  "$DEST/bin/run.sh" root/conf.yaml
) &

echo ">>> Waiting for gateway to listen on :5000..."
for i in $(seq 1 90); do
  if ss -ltn sport = :5000 | grep -q ':5000'; then
    echo ">>> Gateway is up on :5000"
    break
  fi
  sleep 2
done

if ! ss -ltn sport = :5000 | grep -q ':5000'; then
  echo "ERROR: Gateway did not start on :5000" >&2
  exit 1
fi

# Render provides PORT; fail fast if it isn't present.
: "${PORT:?PORT env var must be set by Render}"

echo ">>> Writing Nginx config (listen ${PORT} -> https://127.0.0.1:5000)..."
/bin/cat >/etc/nginx/conf.d/default.conf <<NGINX
server {
    listen ${PORT};
    server_name _;

    location / {
        proxy_pass https://127.0.0.1:5000;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # IBKR uses its own cert; let us proxy anyway
        proxy_ssl_server_name on;
        proxy_ssl_verify off;

        proxy_read_timeout 300s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
    }
}
NGINX

echo ">>> Launching Nginx in the foreground..."
exec nginx -g 'daemon off;'

