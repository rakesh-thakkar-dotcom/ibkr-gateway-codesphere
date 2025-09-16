#!/bin/bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Render provides $PORT (the public HTTP listener inside the container).
RENDER_PORT="${PORT:-10000}"
GATEWAY_PORT=5000
IBKR_ZIP_URL="${IBKR_ZIP_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"
EXTRACT_DIR="/home/app/ibgateway"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"
echo ">>> IBKR bundle URL: $IBKR_ZIP_URL"

# --- Download the IBKR bundle (once per boot) ---
echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip

# --- Fresh unzip into EXTRACT_DIR ---
echo ">>> Unzipping Gateway..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -oq /tmp/clientportal.gw.zip -d "$EXTRACT_DIR"

echo ">>> Listing extracted contents (top-level):"
ls -la "$EXTRACT_DIR"

# --- Sanity checks (paths used by vendor scripts) ---
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

# --- Start gateway from the extracted dir (so relative classpaths resolve) ---
cd "$EXTRACT_DIR"

echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
./bin/run.sh root/conf.yaml &

# --- Wait for HTTPS on :5000 (use curl; no nc dependency) ---
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..120}; do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null --max-time 1; then
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# --- Nginx config (run as non-root; log to stdout/stderr) ---
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

  # IBKR auth can set large cookies; give us headroom
  client_max_body_size 10m;
  large_client_header_buffers 4 32k;
  proxy_buffers 16 8k;
  proxy_buffer_size 64k;
  proxy_busy_buffers_size 64k;

  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  server {
    listen       __RENDER_PORT__;
    server_name  _;

    # Main proxy to the internal HTTPS gateway on :5000
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

      # Preserve these for SSO/CSRF checks
      proxy_set_header Referer           $http_referer;
      proxy_set_header Origin            $http_origin;

      proxy_http_version 1.1;

      # Backend is TLS with an internal/self-signed cert
      proxy_ssl_verify      off;
      proxy_ssl_server_name off;

      # --- Fix absolute redirects from backend (any path) ---
      proxy_redirect ~^https://(localhost|127\.0\.0\.1):5000(/.*)?$ https://$host$2;

      # --- Rewrite cookie domains from localhost/127.0.0.1 to our host ---
      proxy_cookie_domain ~^(localhost|127\.0\.0\.1)$ $host;

      # --- Append attributes so browsers keep cookies across redirects ---
      proxy_cookie_path / "/; Secure; SameSite=None";
    }
  }
}
NGX

# Inject actual port Render expects us to bind to
sed -i "s/__RENDER_PORT__/${RENDER_PORT}/g" /tmp/ibkr-nginx.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'

