#!/usr/bin/env bash
set -euo pipefail

echo ">>> Starting entrypoint"

PORT="${PORT:-10000}"
GATEWAY_PORT="${GATEWAY_PORT:-5000}"
IBKR_BUNDLE_URL="${IBKR_BUNDLE_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"

echo ">>> Render PORT: ${PORT}"
echo ">>> Internal Gateway HTTPS port: ${GATEWAY_PORT}"
echo ">>> IBKR bundle URL: ${IBKR_BUNDLE_URL}"

# Clean old bundle if any
rm -rf ./bin ./build ./dist ./doc ./root || true

# Download + unzip the IBKR Gateway bundle fresh each start
echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "$IBKR_BUNDLE_URL" -o clientportal.gw.zip
echo ">>> Unzipping Gateway..."
unzip -q clientportal.gw.zip
rm -f clientportal.gw.zip

echo ">>> Listing extracted contents (top-level):"
ls -alh

# Start the IBKR Gateway (vendor script)
echo ">>> Starting IBKR Gateway (HTTPS on :${GATEWAY_PORT})..."
chmod +x ./bin/run.sh || true
./bin/run.sh root/conf.yaml &

# Wait until the gateway answers on 127.0.0.1:${GATEWAY_PORT} over HTTPS
echo ">>> Waiting for gateway to listen on :${GATEWAY_PORT}..."
for i in $(seq 1 90); do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null; then
    echo ">>> Gateway is up on :${GATEWAY_PORT}"
    break
  fi
  sleep 1
done

# Minimal nginx main config
cat >/etc/nginx/nginx.conf <<'NG'
user  root;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events { worker_connections 1024; }

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  # Keep things simple and transparent
  sendfile        on;
  tcp_nopush      on;
  tcp_nodelay     on;

  # Increase header buffers for IBKR pages
  large_client_header_buffers 4 16k;

  # Don’t rewrite redirects
  proxy_redirect          off;
  proxy_buffering         off;
  proxy_request_buffering off;

  # Longer timeouts for streaming/WebSocket-ish behavior
  proxy_read_timeout  3600s;
  proxy_send_timeout  3600s;

  # Let underscores pass (some gateways use them)
  underscores_in_headers on;

  # Include our server block
  include /etc/nginx/conf.d/*.conf;
}
NG

echo ">>> Launching Nginx in the foreground..."
exec nginx -g 'daemon off;'
