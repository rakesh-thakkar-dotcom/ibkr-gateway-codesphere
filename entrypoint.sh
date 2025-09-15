#!/usr/bin/env bash
set -Eeuo pipefail

echo ">>> Starting entrypoint"

# ----- Constants & paths -----
DEST="${HOME}/ibgateway"
ZIP="/tmp/clientportal.gw.zip"
GATEWAY_INTERNAL_PORT=5000         # IBKR Gateway always runs HTTPS on 5000 internally
RENDER_PORT="${PORT:-10000}"       # Render injects PORT; default for local dev

echo ">>> Render incoming HTTP PORT: ${RENDER_PORT}"
echo ">>> Internal Gateway HTTPS port: ${GATEWAY_INTERNAL_PORT}"

# ----- Fetch & unpack the IBKR Client Portal Gateway -----
echo ">>> Fetching IBKR Client Portal Gateway..."
mkdir -p "${DEST}"
curl -fsSL -o "${ZIP}" "https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Unzipping Gateway..."
unzip -oq "${ZIP}" -d "${DEST}"

echo ">>> Making run.sh executable..."
chmod +x "${DEST}/bin/run.sh"

# ----- Start the Gateway (HTTPS on :5000) in the background -----
echo ">>> Starting IBKR Gateway (HTTPS on :${GATEWAY_INTERNAL_PORT})..."
(
  cd "${DEST}"
  "${DEST}/bin/run.sh" "root/conf.yaml"
) &

# ----- Wait for the gateway to begin listening on :5000 -----
echo ">>> Waiting for gateway to listen on :${GATEWAY_INTERNAL_PORT}..."
for i in $(seq 1 90); do
  if ss -ltpn 2>/dev/null | grep -q ":${GATEWAY_INTERNAL_PORT} "; then
    echo ">>> Gateway is up on :${GATEWAY_INTERNAL_PORT}"
    break
  fi
  sleep 1
  if [[ $i -eq 90 ]]; then
    echo "!!! Gateway did not come up on :${GATEWAY_INTERNAL_PORT} within 90s" >&2
    exit 1
  fi
done

# ----- Prepare Nginx temp paths (must be writable) -----
echo ">>> Ensuring Nginx temp paths exist..."
for d in client_body proxy fastcgi uwsgi scgi; do
  mkdir -p "${HOME}/nginx/tmp/${d}"
done

# ----- Write Nginx config: listen on $PORT -> proxy to https://127.0.0.1:5000 -----
echo ">>> Writing Nginx config (listen ${RENDER_PORT} -> https://127.0.0.1:${GATEWAY_INTERNAL_PORT})..."

cat > "${HOME}/nginx.conf" <<'NGINX'
worker_processes  1;

events {
  worker_connections  1024;
}

http {
  # No 'include mime.types;' — that file doesn't exist in this image
  default_type  application/octet-stream;
  sendfile      on;
  keepalive_timeout  65;

  # Writable temp paths
  client_body_temp_path $HOME/nginx/tmp/client_body;
  proxy_temp_path       $HOME/nginx/tmp/proxy;
  fastcgi_temp_path     $HOME/nginx/tmp/fastcgi;
  uwsgi_temp_path       $HOME/nginx/tmp/uwsgi;
  scgi_temp_path        $HOME/nginx/tmp/scgi;

  # Upstream is the IBKR Gateway on HTTPS 127.0.0.1:5000
  upstream ibkr_upstream {
    server 127.0.0.1:5000;
  }

  server {
    listen PORT_TO_LISTEN;

    # Forward headers to keep client IP / host info
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # The Gateway uses a self-signed cert
    proxy_ssl_server_name on;
    proxy_ssl_verify off;

    location / {
      proxy_pass https://ibkr_upstream;
    }
  }
}
NGINX

# Substitute the render port into the config
sed -i "s/PORT_TO_LISTEN/${RENDER_PORT}/g" "${HOME}/nginx.conf"

# ----- Launch Nginx in the foreground -----
echo ">>> Launching Nginx in the foreground..."
exec nginx -c "${HOME}/nginx.conf" -g 'daemon off;'
