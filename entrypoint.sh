#!/usr/bin/env bash
set -Eeuo pipefail

echo ">>> Starting entrypoint"

# ----- Paths & ports -----
DEST="/home/app/ibgateway"
ZIP="/tmp/clientportal.gw.zip"
GATEWAY_INTERNAL_PORT=5000                 # IBKR Gateway HTTPS
RENDER_PORT="${PORT:-10000}"               # Render-injected public port
NGX_TMP="/tmp/ibkr-nginx"
NGX_CONF="/tmp/ibkr-nginx.conf"

echo ">>> Render incoming HTTP PORT: ${RENDER_PORT}"
echo ">>> Internal Gateway HTTPS port: ${GATEWAY_INTERNAL_PORT}"

# ----- Fetch & unpack IBKR Client Portal Gateway -----
echo ">>> Fetching IBKR Client Portal Gateway..."
mkdir -p "${DEST}"
curl -fsSL -o "${ZIP}" "https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Unzipping Gateway..."
unzip -oq "${ZIP}" -d "${DEST}"

echo ">>> Making run.sh executable..."
chmod +x "${DEST}/bin/run.sh"

# ----- Start the Gateway (HTTPS :5000) in background -----
echo ">>> Starting IBKR Gateway (HTTPS on :${GATEWAY_INTERNAL_PORT})..."
(
  cd "${DEST}"
  "${DEST}/bin/run.sh" "root/conf.yaml"
) &

# ----- Wait for the gateway to listen -----
echo ">>> Waiting for gateway to listen on :${GATEWAY_INTERNAL_PORT}..."
for i in $(seq 1 120); do
  if ss -ltpn 2>/dev/null | grep -q ":${GATEWAY_INTERNAL_PORT} "; then
    echo ">>> Gateway is up on :${GATEWAY_INTERNAL_PORT}"
    break
  fi
  sleep 1
  if [[ $i -eq 120 ]]; then
    echo "!!! Gateway did not come up on :${GATEWAY_INTERNAL_PORT} within 120s" >&2
    exit 1
  fi
done

# ----- Nginx temp dirs -----
echo ">>> Ensuring Nginx temp paths exist..."
mkdir -p "${NGX_TMP}/client_body" "${NGX_TMP}/proxy" "${NGX_TMP}/fastcgi" "${NGX_TMP}/uwsgi" "${NGX_TMP}/scgi"

# ----- Nginx config: listen $PORT -> proxy https://127.0.0.1:5000 with cookie/redirect/link rewrites -----
echo ">>> Writing Nginx config (listen ${RENDER_PORT} -> https://127.0.0.1:${GATEWAY_INTERNAL_PORT})..."
cat > "${NGX_CONF}" <<NGINX
worker_processes  1;

events {
  worker_connections  1024;
}

http {
  default_type  application/octet-stream;
  sendfile      on;
  keepalive_timeout  65;

  # Absolute temp paths
  client_body_temp_path ${NGX_TMP}/client_body;
  proxy_temp_path       ${NGX_TMP}/proxy;
  fastcgi_temp_path     ${NGX_TMP}/fastcgi;
  uwsgi_temp_path       ${NGX_TMP}/uwsgi;
  scgi_temp_path        ${NGX_TMP}/scgi;

  upstream ibkr_upstream {
    server 127.0.0.1:${GATEWAY_INTERNAL_PORT};   # IBKR gateway HTTPS
  }

  server {
    listen ${RENDER_PORT};

    # Forward headers
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # ---- TLS to upstream (IBKR gateway uses self-signed cert) ----
    proxy_ssl_server_name on;          # send SNI
    proxy_ssl_name localhost;          # set SNI to 'localhost'
    proxy_ssl_protocols TLSv1.2 TLSv1.3;
    proxy_ssl_verify off;

    # ---- Rewrite cookies & redirects coming back as localhost ----
    proxy_cookie_domain localhost \$host;     # Set-Cookie Domain=localhost -> your public host
    proxy_redirect https://localhost:5000/ /;

    # ---- Rewrite absolute links in HTML (e.g., https://localhost:5000/...) ----
    sub_filter_types text/html text/css application/javascript application/json;
    sub_filter_once off;
    proxy_set_header Accept-Encoding "";     # disable upstream gzip so sub_filter works
    sub_filter "https://localhost:5000" "https://\$host";

    location / {
      proxy_http_version 1.1;
      proxy_pass https://ibkr_upstream;
    }
  }
}
NGINX

# ----- Launch Nginx in the foreground -----
echo ">>> Launching Nginx in the foreground..."
exec nginx -c "${NGX_CONF}" -g 'daemon off;'

