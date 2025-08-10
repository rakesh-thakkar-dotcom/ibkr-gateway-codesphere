#!/usr/bin/env bash
set -euo pipefail

GW_DIR="/opt/ibkr/clientportal.gw"
GW_ZIP_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo "==> Ensuring IBKR Client Portal Gateway is present..."
if [ ! -d "$GW_DIR" ]; then
  echo "==> Downloading gateway..."
  curl -L -o /opt/ibkr/clientportal.gw.zip "$GW_ZIP_URL"
  echo "==> Unzipping..."
  unzip -q /opt/ibkr/clientportal.gw.zip -d /opt/ibkr/
  rm -f /opt/ibkr/clientportal.gw.zip
fi

cd "$GW_DIR"

# The gateway defaults to HTTPS on port 5000 and will bind inside the container.
# Codesphere will proxy this out once you open the port in the UI.
echo "==> Starting IBKR Client Portal Gateway..."
# Run in foreground so container stays alive
exec bash bin/run.sh
