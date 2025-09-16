#!/bin/bash
set -euo pipefail

echo ">>> Starting entrypoint"

RENDER_PORT="${PORT:-10000}"         # Render’s required listener
GATEWAY_PORT=5000                    # IBKR’s internal HTTPS
IBKR_ZIP_URL="${IBKR_ZIP_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"
EXTRACT_DIR="/home/app/ibgateway"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"
echo ">>> IBKR bundle URL: $IBKR_ZIP_URL"

# Download bundle fresh each boot (keeps us on IBKR’s expected structure)
echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip

echo ">>> Unzipping Gateway..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -oq /tmp/clientportal.gw.zip -d "$EXTRACT_DIR"

echo ">>> Listing extracted contents (top-level):"
ls -la "$EXTRACT_DIR"

# Sanity checks
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

# Start gateway (it uses its own Java; keep CWD so relative classpaths resolve)
cd "$EXTRACT_DIR"
echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
./bin/run.sh root/conf.yaml &

# Wait for HTTPS on :5000 without nc
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..120}; do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null --max-time 1; then
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# Derive public host for rewriting. Render sets X-Forwarded-Host for external reqs,
# but here we must pick something static. Use the first Host seen at runtime if present;
# otherwise fall back to an env var or known domain.
PUBLIC_HOST_DEFAULT="${PUBLIC_HOST:-ibkr-gateway-codesphere.onrender.com}"

echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi

# Build nginx.conf with:
# - proxy_redirect regex for absolute redirects
# - proxy_cookie_domain rewrite
# - proxy_cookie_flags to force Secure; SameSite=None
# - sub_filter to rewrite any 'https://localhost:5000' (and 127.0.0.1) in HTML/JS/CSS/etc.
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

  # Bigger buffers; IBKR sets chunky headers/cookies
  client_max_body_size 10m;
  large_client_header_buffers 8 64k;
  proxy_buffers 16 16k;
  proxy_buffer_size 64k;
  proxy_busy_buffers_size 128k;

  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  # We’ll substitute localhost URLs inside any text-like response.
  # NOTE: This is safe here because IBKR serves mostly HTML/JS/CSS from /sso/* and root.
  # We enable on all types to catch JS bundles as well.
  # The replacement host is injected below with SED.
  sub_filter_types *;
  sub_filter_once off;

  server {
    listen       __RENDER_PORT__;
    server_name  _;

    # Set this variable so sub_filter has the correct public scheme+host
    set $public_base https://__PUBLIC_HOST__;

    # Body rewriting for hard-coded localhost URLs (both 127.0.0.1 and localhost)
    sub_filter "https://localhost:5000"   $public_base;
    sub_filter "https://127.0.0.1:5000"   $public_base;

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

      # Preserve for CSRF checks
      proxy_set_header Referer           $http_referer;
      proxy_set_header Origin            $http_origin;

      proxy_http_version 1.1;

      # Backend uses self-signed TLS; we trust it locally
      proxy_ssl_verify      off;
      proxy_ssl_server_name off;

      # Fix absolute redirects pointing to localhost
      proxy_redirect ~^https://(localhost|127\.0\.0\.1):5000(/.*)?$ https://$host$2;

      # Rewrite cookie domain if present
      proxy_cookie_domain ~^(localhost|127\.0\.0\.1)$ $host;

      # Force modern cookie attributes (stronger than appending)
      proxy_cookie_flags ~ Secure SameSite=None;

      # As a belt-and-suspenders, still append attributes on path
      proxy_cookie_path / "/; Secure; SameSite=None";
    }
  }
}
NGX

# Inject actual values
sed -i "s/__RENDER_PORT__/${RENDER_PORT}/g" /tmp/ibkr-nginx.conf
sed -i "s/__PUBLIC_HOST__/${PUBLIC_HOST_DEFAULT}/g" /tmp/ibkr-nginx.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'

