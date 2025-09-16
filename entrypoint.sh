#!/bin/bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Render injects $PORT; default 10000 for local runs.
RENDER_PORT="${PORT:-10000}"
GATEWAY_PORT=5000
IBKR_ZIP_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"
EXTRACT_DIR="/home/app/ibgateway"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"
echo ">>> IBKR bundle URL: $IBKR_ZIP_URL"

# Download once per boot
if [ ! -f /tmp/clientportal.gw.zip ]; then
  echo ">>> Downloading IBKR Client Portal Gateway..."
  curl -fsSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip
fi

# Fresh extract
echo ">>> Unzipping Gateway..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -oq /tmp/clientportal.gw.zip -d "$EXTRACT_DIR"

# Sanity checks
echo ">>> Listing extracted contents (top-level):"
ls -la "$EXTRACT_DIR"

if [ ! -d "$EXTRACT_DIR/bin" ] || [ ! -f "$EXTRACT_DIR/bin/run.sh" ]; then
  echo "!!! ERROR: Expected launcher not found under $EXTRACT_DIR/bin"
  find "$EXTRACT_DIR" -maxdepth 2 -type f -name "run.sh" -print || true
  exit 1
fi

if [ ! -f "$EXTRACT_DIR/root/conf.yaml" ]; then
  echo "!!! ERROR: Expected config at $EXTRACT_DIR/root/conf.yaml not found."
  find "$EXTRACT_DIR" -maxdepth 2 -type f -name "conf.yaml" -print || true
  exit 1
fi

chmod +x "$EXTRACT_DIR/bin/run.sh"

# IMPORTANT: run from the extracted dir so run.sh's relative classpath works
cd "$EXTRACT_DIR"

echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
./bin/run.sh root/conf.yaml &

# Wait for the gateway to accept HTTPS on :5000 (no netcat, use curl+TCP)
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..120}; do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null --max-time 1; then
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# Nginx temp dirs in /tmp (non-root safe)
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi

# Minimal Nginx config: listen on $PORT and proxy to https://127.0.0.1:5000
cat >/tmp/ibkr-nginx.conf <<'NGX'
worker_processes  1;
pid /tmp/nginx.pid;

events { worker_connections 1024; }

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  access_log /dev/stdout;
  error_log  /dev/stderr info;

  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  server {
    listen       __RENDER_PORT__;
    server_name  _;

    location / {
      proxy_pass https://127.0.0.1:5000;

      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-Port  443;

      proxy_http_version 1.1;
      proxy_set_header Upgrade           $http_upgrade;
      proxy_set_header Connection        "upgrade";

      proxy_ssl_verify      off;
      proxy_ssl_server_name off;

      proxy_redirect https://localhost:5000/  /;
      proxy_redirect https://127.0.0.1:5000/  /;
      proxy_cookie_domain  localhost  $host;
      proxy_cookie_domain  127.0.0.1  $host;
    }
  }
}
NGX

# Inject actual Render port
sed -i "s/__RENDER_PORT__/${RENDER_PORT}/g" /tmp/ibkr-nginx.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'
