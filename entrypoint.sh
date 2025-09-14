#!/usr/bin/env bash
set -euo pipefail

DEST=${DEST:-/opt/ibgateway}
ZIP=/tmp/clientportal.gw.zip
URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo "[IBKR] Downloading gateway..."
curl -fsSL "$URL" -o "$ZIP"

echo "[IBKR] Unzipping..."
rm -rf "$DEST" && mkdir -p "$DEST"
unzip -o "$ZIP" -d "$DEST" > /dev/null

chmod +x "$DEST/bin/run.sh"

echo "[IBKR] Starting gateway on port 5000..."
cd "$DEST"
exec "$DEST/bin/run.sh" "$DEST/root/conf.yaml"
