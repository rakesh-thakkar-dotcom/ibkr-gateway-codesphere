#!/usr/bin/env bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Render provides $PORT; default for local runs:
export PORT="${PORT:-10000}"

# IBKR gateway listens on HTTPS :5000 inside the container
export GATEWAY_PORT="${GATEWAY_PORT:-5000}"
export IBKR_BUNDLE_URL="${IBKR_BUNDLE_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"

CONF_ROOT="/home/app/nginx-conf"
CONF_D="$CONF_ROOT/conf.d"
RUNTIME_ROOT="/home/app/nginx-runtime"

echo ">>> Render PORT: ${PORT}"
echo ">>> Internal Gateway HTTPS port: ${GATEWAY_PORT}"
echo ">>> IBKR bundle URL: ${IBKR_BUNDLE_URL}"

# --- Download & unpack IBKR Client Portal Gateway ---
echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "$IBKR_BUNDLE_URL" -o clientportal.gw.zip
echo ">>> Unzipping Gateway..."
rm -rf ./bin ./build ./dist ./doc ./root || true
unzip -q clientportal.gw.zip
rm -f clientportal.gw.zip

echo ">>> Listing extracted contents (top-level):"
ls -alh

# --- Start the IBKR Gateway (HTTPS on 127.0.0.1:$GATEWAY_PORT) ---
echo ">>> Starting IBKR Gateway (HTTPS on :${GATEWAY_PORT})..."
chmod +x ./bin/run.sh || true
(
  set -x
  ./bin/run.sh root/conf.yaml &
)

# Wait up to ~60s for it to respond over HTTPS
echo ">>> Waiting for gateway to listen on :${GATEWAY_PORT}..."
for i in {1..60}; do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null; then
    echo ">>> Gateway is up on :${GATEWAY_PORT}"
    break
  fi
  sleep 1
done

# --- Ensure Nginx runtime paths exist (all under /home/app, all writable) ---
mkdir -p \
  "${RUNTIME_ROOT}/client_temp" \
  "${RUNTIME_ROOT}/proxy_temp" \
  "${RUNTIME_ROOT}/fastcgi_temp" \
  "${RUNTIME_ROOT}/uwsgi_temp" \
  "${RUNTIME_ROOT}/scgi_temp" \
  "${CONF_D}"

# --- Write Nginx config (template -> final) ---
if [ -f "./nginx/app.conf" ]; then
  echo ">>> Writing Nginx config from nginx/app.conf (templated) -> ${CONF_D}/app.conf"
  sed -e "s/__PORT__/${PORT}/g" \
      -e "s/__GATEWAY_PORT__/${GATEWAY_PORT}/g" \
      ./nginx/app.conf > "${CONF_D}/app.conf"
else
  echo ">>> Writing Nginx config (inline fallback) -> ${CONF_D}/app.conf"
  cat > "${CONF_D}/app.conf" <<'NGINX'
server {
    listen 0.0.0.0:__PORT__;
    server_name _;

    large_client_header_buffers 8 64k;

    location / {
        proxy_pass https://127.0.0.1:__GATEWAY_PORT__;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Force what the app expects behind TLS edge
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;

        # WebSocket/SSE
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # Rewrite absolute redirects from the gateway
        proxy_redirect https://127.0.0.1:__GATEWAY_PORT__/ $scheme://$host/;
        proxy_redirect https://localhost:__GATEWAY_PORT__/ $scheme://$host/;
        proxy_redirect https://localhost/ $scheme://$host/;
    }

    location = /healthz { return 200 "ok\n"; add_header Content-Type text/plain; }
}
NGINX
  # fill placeholders for fallback
  sed -i "s/__PORT__/${PORT}/g; s/__GATEWAY_PORT__/${GATEWAY_PORT}/g" "${CONF_D}/app.conf"
fi

# --- Launch Nginx in the foreground using our config under /home/app ---
echo ">>> Launching Nginx in the foreground..."
exec nginx -c "${CONF_ROOT}/nginx.conf" -g 'daemon off;'


