#!/bin/bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Ports
RENDER_PORT="${PORT:-10000}"        # Render injects $PORT; default for local
GATEWAY_PORT=5000
IBKR_ZIP_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"

# Download IBKR Gateway if not already cached this boot
if [ ! -f /tmp/clientportal.gw.zip ]; then
  echo ">>> Fetching IBKR Client Portal Gateway from $IBKR_ZIP_URL ..."
  curl -sSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip
fi

echo ">>> Unzipping Gateway..."
mkdir -p /home/app/ibgateway
unzip -o /tmp/clientportal.gw.zip -d /home/app/ibgateway > /dev/null

# Ensure run.sh is executable (IBKR ships it inside the zip)
chmod +x /home/app/ibgateway/run.sh || true

echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
/home/app/ibgateway/run.sh root/conf.yaml &

# --- Wait for :5000 without netcat (use Bash's /dev/tcp) ---
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..90}; do
  if (exec 3<>/dev/tcp/127.0.0.1/$GATEWAY_PORT) 2>/dev/null; then
    exec 3>&- 3<&-
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# Prepare temp dirs Nginx will need (keep them under /tmp)
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi

# Generate an Nginx config that:
# - Listens on $PORT
# - Proxies to the IBKR HTTPS gateway on 127.0.0.1:5000
# - Rewrites redirects and cookies from localhost -> your Render host
# - Disables upstream TLS verification (self-signed)
cat >/tmp/ibkr-nginx.conf <<'NGX'
worker_processes  1;

events { worker_connections 1024; }

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  # Temp paths must be writable by the running user
  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  server {
    listen       __RENDER_PORT__;
    server_name  _;

    # Proxy everything to the local HTTPS IBKR gateway
    location / {
      proxy_pass https://127.0.0.1:5000;

      # Forward proto/host so the app knows it's behind HTTPS
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-Port  443;

      # WebSockets (IBKR uses them)
      proxy_http_version 1.1;
      proxy_set_header Upgrade           $http_upgrade;
      proxy_set_header Connection        "upgrade";

      # Upstream uses self-signed cert
      proxy_ssl_verify     off;
      proxy_ssl_server_name off;

      # Fix redirects like Location: https://localhost:5000/...
      proxy_redirect https://localhost:5000/  /;
      proxy_redirect https://127.0.0.1:5000/  /;

      # Fix cookies set for localhost so browser stores them for your host
      proxy_cookie_domain  localhost       $host;
      proxy_cookie_domain  127.0.0.1       $host;
    }
  }
}
NGX

# Inject actual port into the config template
sed -i "s/__RENDER_PORT__/${RENDER_PORT}/g" /tmp/ibkr-nginx.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'

