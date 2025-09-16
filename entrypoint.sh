#!/bin/bash
set -e

echo ">>> Starting entrypoint"

# Ports
RENDER_PORT="${PORT:-10000}"
GATEWAY_PORT=5000
IBKR_ZIP_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Render PORT: $RENDER_PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"

# Download IBKR Gateway if not present
if [ ! -f /tmp/clientportal.gw.zip ]; then
  echo ">>> Fetching IBKR Client Portal Gateway from $IBKR_ZIP_URL ..."
  curl -sSL "$IBKR_ZIP_URL" -o /tmp/clientportal.gw.zip
fi

echo ">>> Unzipping Gateway..."
mkdir -p /home/app/ibgateway
unzip -o /tmp/clientportal.gw.zip -d /home/app/ibgateway > /dev/null

# Ensure run.sh is executable
chmod +x /home/app/ibgateway/run.sh || true

echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
/home/app/ibgateway/run.sh root/conf.yaml &

# Wait until gateway responds
echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..60}; do
  if nc -z 127.0.0.1 $GATEWAY_PORT; then
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# Prepare Nginx paths
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p /tmp/nginx/client_body

# Generate Nginx config with proxy + rewrite fixes
cat >/tmp/ibkr-nginx.conf <<EOL
worker_processes  1;
events { worker_connections 1024; }
http {
  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path       /tmp/nginx/proxy;
  fastcgi_temp_path     /tmp/nginx/fastcgi;
  uwsgi_temp_path       /tmp/nginx/uwsgi;
  scgi_temp_path        /tmp/nginx/scgi;

  server {
    listen $RENDER_PORT;

    location / {
      proxy_pass https://127.0.0.1:$GATEWAY_PORT;

      # Forward headers
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;

      # Fix redirects from localhost
      proxy_redirect https://127.0.0.1:$GATEWAY_PORT/ /;
      proxy_redirect https://localhost:$GATEWAY_PORT/ /;

      # Fix cookies from localhost
      proxy_cookie_domain 127.0.0.1 \$host;
      proxy_cookie_domain localhost \$host;

      # Allow websockets
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
EOL

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /tmp/ibkr-nginx.conf -g 'daemon off;'


