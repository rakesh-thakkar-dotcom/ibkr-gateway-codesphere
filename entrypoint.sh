#!/usr/bin/env bash
set -euo pipefail

# --------------------------
# Config
# --------------------------
# Render injects $PORT (e.g., 10000). Default to 10000 if not set (useful for local runs).
PORT="${PORT:-10000}"
GW_DIR="/home/app/ibgateway"
GW_ZIP="/tmp/clientportal.gw.zip"

echo ">>> Starting entrypoint"
echo ">>> Render incoming PORT: ${PORT}"

# --------------------------
# Fetch & unpack IBKR Gateway
# --------------------------
echo ">>> Fetching IBKR Client Portal Gateway..."
# If your Dockerfile already bakes the zip in, you can skip the curl and
# just ensure $GW_ZIP exists before unzip. Otherwise, uncomment the next line
# with the official download URL you were using previously.
#
# curl -fsSL "https://<your-ibkr-gateway-zip-url>" -o "${GW_ZIP}"

# If a previous run left the folder, re-create it cleanly
rm -rf "${GW_DIR}"
mkdir -p "${GW_DIR}"

echo ">>> Unzipping Gateway..."
unzip -qo "${GW_ZIP}" -d "${GW_DIR}"

chmod +x "${GW_DIR}/run.sh"

# --------------------------
# Start the Gateway
# --------------------------
# IMPORTANT:
# We bind to 0.0.0.0 so Render can reach it, and we pass the Render port.
# Some IBKR Gateway builds accept CLI flags; if yours differs, keep "root/conf.yaml"
# and add/adjust the flags below so the service listens on ${PORT} at 0.0.0.0.
#
# If your binary doesn’t support these flags, remove them, but **it must**
# listen on ${PORT} and on 0.0.0.0 for Render to work without a proxy.

echo ">>> Starting IBKR Gateway on 0.0.0.0:${PORT} ..."
# Try the most common flag forms; comment/uncomment as needed for your build.
# 1) If your run.sh supports --port and --host:
exec "${GW_DIR}/run.sh" root/conf.yaml --port "${PORT}" --host "0.0.0.0"

# --------------------------
# Notes / Alternatives
# --------------------------
# If your run.sh does NOT support --port/--host flags, you have two choices:
#  A) Modify the gateway config so it listens on ${PORT} and on 0.0.0.0
#  B) Re-introduce a tiny HTTP reverse-proxy on ${PORT} (e.g., nginx or caddy)
#     and keep the gateway listening on 5000 HTTPS internally.
#
# For this script we aim for the simplest: bind the gateway directly to ${PORT}.

