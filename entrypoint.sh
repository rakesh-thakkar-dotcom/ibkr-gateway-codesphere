#!/usr/bin/env bash
set -euo pipefail

echo ">>> Starting entrypoint"

# Render provides $PORT; default for local runs:
export PORT="${PORT:-10000}"

# Your IBKR gateway listens on HTTPS :5000 inside the container
export GATEWAY_PORT="${GATEWAY_PORT:-5000}"
export IBKR_BUNDLE_URL="${IBKR_BUNDLE_URL:-https://download2.interactivebrokers.com/portal/clientportal.gw.zip}"

echo ">>> Render PORT: ${PORT}"
echo ">>> Internal Gateway HTTPS port: ${GATEWAY_PORT}"
echo ">>> IBKR bundle URL: ${IBKR_BUNDLE_URL}"

# --- Download & unpack IBKR Client Portal Gateway (fresh on every boot) ---
echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "$IBKR_BUNDLE_URL" -o clientportal.gw.zip
echo ">>> Unzipping Gateway..."
rm -rf ./bin ./build ./dist ./doc ./root || true
unzip -q clientportal.gw.zip
rm -f clientportal.gw.zip

echo ">>> Listing extracted contents (top-level):"
ls -alh

# --- Start the IBKR Gateway (HTTPS on 127.0.0.1:$GATEWAY_PORT) ---
echo ">>> Starting IBKR Gateway (HTTPS on :${GATEWAY_PORT})..."
# The JAR and conf.yaml come from the bundle
# It self-binds to 127.0.0.1 and serves HTTPS
(
  set -x
  java -jar dist/ibgroup.web.core.iblink.router.clientportal.gw.jar --config root/conf.yaml &
)
# Wait a moment for it to come up
echo ">>> Waiting for gateway to listen on :${GATEWAY_PORT}..."
for i in {1..60}; do
  if curl -sk "https://127.0.0.1:${GATEWAY_PORT}/" -o /dev/null; then
    break
  fi
  sleep 1
done
echo ">>> Gateway is up on :${GATEWAY_PORT}"

# --- Ensure Nginx paths exist ---
mkdir -p /var/cache/nginx /var/run /var/log/nginx

# --- Write Nginx config ---
# If you created nginx/app.conf in your repo, we’ll transform its placeholders.
# Otherwise we’ll fall back to a safe inline config.
if [ -f "./nginx/app.conf" ]; then
  echo ">>> Writing Nginx config from nginx/app.conf (templated)..."
  mkdir -p /etc/nginx/conf.d
  sed -e "s/__PORT__/${PORT}/g" \
      -e "s/__GATEWAY_PORT__/${GATEWAY_PORT}/g" \
      ./nginx/app.conf > /etc/nginx/conf.d/app.conf
else
  echo ">>> Writing Nginx config (inline fallback)..."
  cat >/etc/nginx/conf.d/app.conf <<NGINX
server {
    listen 0.0.0.0:${PORT};
    server_name _;

    # IBKR uses lots of headers/cookies; give headroom
    large_client_header_buffers 4 16k;

    location / {
        proxy_pass https://127.0.0.1:${GATEWAY_PORT};
        proxy_ssl_verify off;
        proxy_http_version 1.1;

        # Preserve original host & client details
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # IMPORTANT: do NOT force http here. Pass through Render's header.
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # WebSocket/SSE friendliness
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # Keep upstream redirects intact
        proxy_redirect off;
    }

    # Simple health check
    location = /healthz { return 200 "ok\n"; add_header Content-Type text/plain; }
}
NGINX
fi

# --- Launch Nginx in foreground (Render expects this to stay in the foreground) ---
echo ">>> Launching Nginx in the foreground..."
exec nginx -g 'daemon off;'

