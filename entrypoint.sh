#!/bin/bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Render provides $PORT for the public listener (HTTP).
RENDER_PORT="${PORT:-10000}"
GATEWAY_PORT=5000
IBKR_ZIP_URL="${IBKR_ZIP_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"
EXTRACT_DIR="/home/app/ibgateway"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"
echo ">>> IBKR bundle URL: $IBKR_ZIP_URL"

# --- Download the IBKR bundle once per boot ---
if [ ! -f /tmp/clientportal.gw.zip ]; then
  echo ">>> Downloading IBKR Client Portal Gateway..."
  curl -fsSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip
fi

# --- Fresh unzip into EXTRACT_DIR ---
echo ">>> Unzipping Gateway..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -oq /tmp/clientportal.gw.zip -d "$EXTRACT_DIR"

echo ">>> Listing extracted contents (top-level):"
ls -la "$EXTRACT_DIR"

# --- Sanity checks expected by the vendor scripts ---
if [ ! -f "$EXTRACT_DIR/bin/run.sh" ]; then
  echo "!!! ERROR: $EXTRACT_DIR/bin/run.sh not found"
  find "$EXTRACT_DIR" -maxdepth 3 -name run.sh -print || true
  exit 1
fi
if [ ! -f "$EXTRACT_DIR/root/conf.yaml" ]; then
  echo "!!! ERROR: $EXTRACT_DIR/root/conf.yaml not found"
  find "$EXTRACT_DIR" -maxdepth 3 -name conf.yaml -print || true
  exit 1
fi
chmod +x "$EXTRACT_DIR/bin/run.sh"

# --- IMPORTANT: run from the extracted dir so relative classpaths resolve ---
cd "$EXTRACT_DIR"

echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
# The vendor script defaults to 5000 TLS based on conf.yaml
./bin/run.sh root/conf.yaml &

# --- Wait for the gateway to accept HTTPS on :5000 (use curl, no nc needed) ---
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..120}; do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null --max-time 1; then
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# --- Nginx config (non-root safe) ---
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi

cat >/tmp/ibkr-nginx.conf <<'NGX'
worker_processes  1;
pid /tmp/nginx.pid;
events { worker_connections 1024; }

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  access_log /dev/stdout;
  error_log  /dev/stderr info;
  server_tokens off;
  absolute_redirect off;

  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  # Ensure big enough headers for cookies
  proxy_buffers 16 8k;
  proxy_buffer_size 16k;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  server {
    listen       __RENDER_PORT__;
    server_name  _;

    # --- Main proxy to the internal HTTPS gateway on :5000 ---
    location / {
      proxy_pass https://127.0.0.1:5000;

      # Standard proxy headers
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-Port  443;
      proxy_set_header Upgrade           $http_upgrade;
      proxy_set_header Connection        $connection_upgrade;

      proxy_http_version 1.1;

      # The backend is TLS with a self-signed / internal cert
      proxy_ssl_verify      off;
      proxy_ssl_server_name off;

      # Fix absolute redirects and cookie domains from the backend
      proxy_redirect https://localhost:5000/  /;
      proxy_redirect https://127.0.0.1:5000/  /;

      # Rewrite cookie domain so browser accepts cookies for your public host
      proxy_cookie_domain localhost  $host;
      proxy_cookie_domain 127.0.0.1  $host;

      # Append cookie attributes so modern browsers keep them
      # This appends to *all* cookies returned by the backend
      proxy_cookie_path / "/; Secure; SameSite=None";
    }
  }
}
NGX

# Inject actual port Render expects us to bind to
sed -i "s/__RENDER_PORT__/${RENDER_PORT}/g" /tmp/ibkr-nginx.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'

