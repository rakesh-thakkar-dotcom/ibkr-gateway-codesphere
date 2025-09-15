#!/usr/bin/env bash
set -euo pipefail

# ---------- Config ----------
: "${PORT:?Render did not supply PORT}"
IBKR_ZIP_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"
IB_HOME="/home/app/ibgateway"
UPSTREAM_HTTPS_PORT="5000"        # IBKR gateway listens here (HTTPS)
RENDER_HOST="${RENDER_HOSTNAME:-ibkr-gateway-codesphere.onrender.com}"  # change if your Render URL differs

echo ">>> Starting entrypoint"
echo ">>> Render PORT: ${PORT}"
echo ">>> Internal Gateway HTTPS port: ${UPSTREAM_HTTPS_PORT}"

# Make sure needed tools exist (image should already include these, but be safe)
command -v unzip >/dev/null || { echo "unzip missing"; exit 1; }
command -v curl  >/dev/null || { echo "curl missing";  exit 1; }
command -v nginx >/dev/null || { echo "nginx missing"; exit 1; }

# Create app user home if not present
mkdir -p "$IB_HOME"

# ---------- Fetch IBKR Gateway ----------
echo ">>> Fetching IBKR Client Portal Gateway from ${IBKR_ZIP_URL} ..."
TMPZIP="/tmp/clientportal.gw.zip"
rm -f "$TMPZIP"
curl -fsSL "$IBKR_ZIP_URL" -o "$TMPZIP"

echo ">>> Unzipping Gateway..."
# Unzip directly into IB_HOME; preserves dist/, bin/, root/ structure
# Use -o to overwrite cleanly on redeploys
unzip -oq "$TMPZIP" -d "$IB_HOME"

# Sanity checks for expected layout
test -x "$IB_HOME/bin/run.sh" || { echo "ERROR: $IB_HOME/bin/run.sh not found after unzip"; ls -la "$IB_HOME"; exit 1; }
test -f "$IB_HOME/root/conf.yaml" || { echo "ERROR: $IB_HOME/root/conf.yaml not found after unzip"; ls -la "$IB_HOME/root"; exit 1; }

echo ">>> Making run.sh executable..."
chmod +x "$IB_HOME/bin/run.sh"

# ---------- Start IBKR Gateway (HTTPS on :5000) ----------
echo ">>> Starting IBKR Gateway (HTTPS on :${UPSTREAM_HTTPS_PORT})..."
(
  cd "$IB_HOME"
  # run.sh prints the "running  runtime path..." log lines you saw
  # It will bind HTTPS on 5000 with the provided conf.yaml
  "$IB_HOME/bin/run.sh" "root/conf.yaml"
) &

echo ">>> Waiting for gateway to listen on :${UPSTREAM_HTTPS_PORT}..."
# Poll the local HTTPS listener until it responds
ATTEMPTS=60
for i in $(seq 1 $ATTEMPTS); do
  if curl -skI "https://127.0.0.1:${UPSTREAM_HTTPS_PORT}/" >/dev/null 2>&1; then
    echo ">>> Gateway is up on :${UPSTREAM_HTTPS_PORT}"
    break
  fi
  sleep 1
  if [[ $i -eq $ATTEMPTS ]]; then
    echo "ERROR: Gateway did not come up on :${UPSTREAM_HTTPS_PORT} in time"
    exit 1
  fi
done

# ---------- Nginx reverse proxy on $PORT ----------
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}

echo ">>> Writing Nginx config (listen ${PORT} -> https://127.0.0.1:${UPSTREAM_HTTPS_PORT})..."
cat >/etc/nginx/conf.d/default.conf <<EOF
server {
    listen       ${PORT};
    access_log   off;
    error_log    /var/log/nginx/error.log warn;

    # IMPORTANT: set to your actual Render hostname (no scheme)
    set \$render_host ${RENDER_HOST};

    # Serve everything through the IBKR gateway (HTTPS upstream)
    location / {
        proxy_pass https://127.0.0.1:${UPSTREAM_HTTPS_PORT};
        proxy_http_version 1.1;

        # Forwarding headers
        proxy_set_header Host              \$render_host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  \$host;

        # Upstream uses self-signed/IBKR cert; we accept it inside the container
        proxy_ssl_verify off;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;

        # --- Fix absolute redirects from the gateway ---
        # e.g., Location: https://localhost:5000/...  ->  https://<render-host>/
        proxy_redirect https://127.0.0.1:${UPSTREAM_HTTPS_PORT}/ https://\$render_host/;
        proxy_redirect https://localhost:${UPSTREAM_HTTPS_PORT}/    https://\$render_host/;

        # --- Fix cookies bound to localhost/127.0.0.1 ---
        proxy_cookie_domain 127.0.0.1 \$render_host;
        proxy_cookie_domain localhost \$render_host;

        proxy_redirect off;
    }

    # Reasonable client body temp path (pre-created)
    client_body_temp_path   /var/cache/nginx/client_temp;
    proxy_temp_path         /var/cache/nginx/proxy_temp;
    fastcgi_temp_path       /var/cache/nginx/fastcgi_temp;
    uwsgi_temp_path         /var/cache/nginx/uwsgi_temp;
    scgi_temp_path          /var/cache/nginx/scgi_temp;

    # Include standard MIME types (avoid duplicate text/html warnings)
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
}
EOF

echo ">>> Launching Nginx in the foreground..."
# Make sure master nginx conf loads our conf.d file
if [[ ! -f /etc/nginx/nginx.conf ]]; then
  # Basic fallback config if the base image misses nginx.conf
  cat >/etc/nginx/nginx.conf <<'NGX'
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
NGX
fi

exec nginx -g 'daemon off;'

