#!/bin/bash
set -e

# Define paths
DEST="/home/app/ibgateway"
ZIP="/tmp/clientportal.gw.zip"

echo ">>> Downloading IBKR Client Portal Gateway..."
mkdir -p "$DEST"
curl -L -o "$ZIP" "https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

echo ">>> Unzipping..."
unzip -o "$ZIP" -d "$DEST"

echo ">>> Making run.sh executable..."
chmod +x "$DEST/bin/run.sh"

echo ">>> Starting IBKR Gateway..."
cd "$DEST"
./bin/run.sh root/conf.yaml
