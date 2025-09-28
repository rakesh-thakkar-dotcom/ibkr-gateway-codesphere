#!/usr/bin/env bash
set -euo pipefail

# --- Render envs ---
: "${PORT:=10000}"   # Render will route to this (no need to set it in the dashboard)

# --- Figure out our public hostname for redirects/cookies ---
# Prefer RENDER_EXTERNAL_HOSTNAME (paid) or fall back to a manual env PUBLIC_HOST
PUBLIC_HOST="${RENDER_EXTERNAL_HOSTNAME:-${PUBLIC_HOST:-}}"
if [[ -z "${PUBLIC_HOST}" ]]; then
  echo "ERROR: PUBLIC_HOST is not set. Set it to your Render hostname (e.g., ibkr-gateway-new-2.onrender.com)."
  exit 1
fi
echo ">>> Using PUBLIC_HOST=${PUBLIC_HOST}"

# --- Paths ---
GW_DIR="/opt/gateway"
mkdir -p "${GW_DIR}"
cd "${GW_DIR}"

# --- Download IBKR Client Portal Gateway bundle ---
echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "https://download2.interactivebrokers.com/portal/clientportal.gw.zip" -o bundle.zip
unzip -q bundle.zip
rm -f bundle.zip

# Sanity: show top-level
echo ">>> Listing extracted contents (top-level):"
ls -lah

# --- Render our conf.yaml from template ---
#echo ">>> Writing root/conf.yaml with PUBLIC_HOST=${PUBLIC_HOST}"
#mkdir -p root
#awk -v h="${PUBLIC_HOST}" '
#  { gsub(/\$\{PUBLIC_HOST\}/, h); print }
#' /conf.public.yaml > root/conf.yaml

cp /conf.public.yaml /opt/gateway/root/conf.yaml

echo ">>> Starting IBKR Gateway (HTTPS on :5000)..."
# Start the gateway in background
./bin/run.sh root/conf.yaml &

# --- Wait for :5000 to be ready ---
echo ">>> Waiting for gateway to listen on :5000..."
for i in {1..60}; do
  if curl -sk https://127.0.0.1:5000/ >/dev/null 2>&1; then
    echo ">>> Gateway is up on :5000"
    break
  fi
  sleep 1
done

# --- Start Nginx (front door on $PORT) ---
echo ">>> Launching Nginx in the foreground..."
nginx -g 'daemon off;'

