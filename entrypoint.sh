#!/bin/bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Render injects $PORT. Default to 10000 for local dev.
RENDER_PORT="${PORT:-10000}"
GATEWAY_PORT=5000
IBKR_ZIP_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"
echo ">>> IBKR bundle URL: $IBKR_ZIP_URL"

# Fetch the IBKR Client Portal Gateway (cache per container boot)
if [ ! -f /tmp/clientportal.gw.zip ]; then
  echo ">>> Downloading IBKR Client Portal Gateway..."
  curl -fsSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip
fi

echo ">>> Unzipping Gateway..."
mkdir -p /home/app/ibgateway
unzip -oq /tmp/clientportal.gw.zip -d /home/app/ibgateway

# IBKR’s launcher lives at bin/run.sh
LAUNCHER="/home/app/ibgateway/bin/run.sh"
if [ ! -f "$LAUNCHER" ]; then
  echo "!!! ERROR: Expected launcher not found at ${LAUNCHER}"
  ls -la /home/app/ibgateway || true
  exit 1
fi
chmod +x "$LAUNCHER"

# Start IBKR (it listens on HTTPS :5000 inside the container)
echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
"$LAUNCHER" root/conf.yaml &

# Wait for :5000 to be reachable WITHOUT netcat (use /dev/tcp)
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..120}; do
  if (exec 3<>/dev/tcp/127.0.0.1/$GATEWAY_PORT) 2>/dev/null; then
    exec 3>&- 3<&-
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# Prepare Nginx temp dirs under /tmp (non-root friendly)
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi

# Write an Nginx conf that:
# - listens on $PORT
# - proxies to https://127.0.0.1:5000 (self-signed)
# - fixes redirects/cookies from localhost to your host
# - logs to stdout/stderr and uses a PID in /tmp (non-root safe)
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

      # Let upstream know original scheme/host
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-Port  443;

      # WebSockets
      proxy_http_version 1.1;
      proxy_set_header Upgrade           $http_upgrade;
      proxy_set_header Connection        "upgrade";

      # Upstream has a self-signed cert
      proxy_ssl_verify      off;
      proxy_ssl_server_name off;

      # Fix redirects and cookies that point to localhost
      proxy_redirect https://localhost:5000/  /;
      proxy_redirect https://127.0.0.1:5000/  /;
      proxy_cookie_domain  localhost  $host;
      proxy_cookie_domain  127.0.0.1  $host;
    }
  }
}
NGX

# Inject actual port
sed -i "s/__RENDER_PORT__/${RENDER_PORT}/g" /tmp/ibkr-nginx.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'

