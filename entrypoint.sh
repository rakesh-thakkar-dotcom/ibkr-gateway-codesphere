#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:-10000}"
GATEWAY_PORT="${GATEWAY_PORT:-5000}"
BUNDLE_URL="${BUNDLE_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"

echo ">>> Render PORT: $PORT"
echo ">>> Internal Gateway HTTPS port: $GATEWAY_PORT"
echo ">>> IBKR bundle URL: $BUNDLE_URL"

cd "${HOME}"

echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "$BUNDLE_URL" -o clientportal.gw.zip

echo ">>> Unzipping Gateway..."
rm -rf bin build dist doc root || true
unzip -q clientportal.gw.zip
rm -f clientportal.gw.zip

echo ">>> Listing extracted contents (top-level):"
ls -alh

echo ">>> Starting IBKR Gateway (HTTPS on :$GATEWAY_PORT)..."
set +e
./bin/run.sh root/conf.yaml &
GATEWAY_PID=$!
set -e

echo ">>> Waiting for gateway to listen on :$GATEWAY_PORT..."
for i in {1..90}; do
  if curl -ks "https://127.0.0.1:${GATEWAY_PORT}/sso/Login?forwardTo=22&RL=1&ip2loc=US" -o /dev/null; then
    echo ">>> Gateway is up on :$GATEWAY_PORT"
    break
  fi
  sleep 1
done

# --------------------------
# NGINX CONFIG (base file)
# --------------------------
echo ">>> Writing base Nginx config -> /home/app/nginx-conf/nginx.conf"
cat > /home/app/nginx-conf/nginx.conf <<NGINX_BASE
worker_processes auto;
pid /home/app/nginx-runtime/nginx.pid;
error_log /dev/stderr info;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                  '\$status \$body_bytes_sent "\$http_referer" '
                  '"\$http_user_agent" "\$http_x_forwarded_for"';
  access_log /dev/stdout main;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;

  client_max_body_size 20m;

  # temp/cache dirs writable by non-root user
  proxy_temp_path /home/app/nginx-runtime/proxy_temp;
  client_body_temp_path /home/app/nginx-runtime/client_temp;
  fastcgi_temp_path /home/app/nginx-runtime/fastcgi_temp;
  uwsgi_temp_path /home/app/nginx-runtime/uwsgi_temp;
  scgi_temp_path /home/app/nginx-runtime/scgi_temp;

  # Propagate original TLS/port from Render (falls back to Nginx's own)
  map \$http_x_forwarded_proto \$real_proto { default \$scheme; ~. \$http_x_forwarded_proto; }
  map \$http_x_forwarded_port  \$real_port  { default \$server_port; ~. \$http_x_forwarded_port; }

  include /home/app/nginx-conf/conf.d/*.conf;
}
NGINX_BASE

# --------------------------
# NGINX vhost (templated)
# --------------------------
mkdir -p /home/app/nginx-conf/conf.d
echo ">>> Writing Nginx vhost from nginx/app.conf (templated) -> /home/app/nginx-conf/conf.d/app.conf"
sed -e "s/__PORT__/${PORT}/g" \
    -e "s/__GATEWAY_PORT__/${GATEWAY_PORT}/g" \
    /home/app/nginx/app.conf > /home/app/nginx-conf/conf.d/app.conf

echo ">>> Launching Nginx in the foreground..."
exec nginx -c /home/app/nginx-conf/nginx.conf -g "daemon off;"
