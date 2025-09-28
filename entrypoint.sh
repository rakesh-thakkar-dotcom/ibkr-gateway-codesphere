#!/usr/bin/env bash
set -euo pipefail

# Render assigns PORT=10000; our nginx listens on 10000 via app.conf.
: "${PORT:=10000}"

GW_DIR="/opt/gateway"
mkdir -p "$GW_DIR"
cd "$GW_DIR"

echo ">>> Downloading IBKR Client Portal Gateway..."
curl -fsSL "https://download2.interactivebrokers.com/portal/clientportal.gw.zip" -o gw.zip
unzip -q gw.zip
rm -f gw.zip

# Show what was unpacked (sanity check)
echo ">>> Listing extracted contents (top-level):"
ls -lah

# Ensure the default config from the bundle is present.
if [[ ! -f root/conf.yaml ]]; then
  echo "ERROR: Missing root/conf.yaml inside the IBKR bundle."
  ls -lah root || true
  exit 1
fi

echo ">>> Starting IBKR Gateway (HTTPS on :5000)..."
# Launch the Java gateway in the background using the bundled config
./bin/run.sh root/conf.yaml &

# Wait for the gateway HTTPS listener to come up on 5000
echo ">>> Waiting for gateway to listen on :5000..."
for i in {1..90}; do
  if curl -sk https://127.0.0.1:5000/ >/dev/null 2>&1; then
    echo ">>> Gateway is up on :5000"
    break
  fi
  sleep 1
done

# Start nginx in the foreground (Render needs the main process to stay in foreground)
echo ">>> Launching Nginx in the foreground..."
nginx -g 'daemon off;'

