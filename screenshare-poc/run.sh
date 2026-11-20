#!/bin/bash
# Starts the media server and the support page, and announces them on the local network
# so the iOS app finds this Mac by itself (Bonjour). Ctrl+C stops everything.
# No -e: background jobs and probes below are allowed to fail without aborting the script.
set -uo pipefail
cd "$(dirname "$0")"
# Run setup on first use if no LiveKit server is available yet.
[ -x tools/livekit-server ] || command -v livekit-server >/dev/null || ./setup.sh || exit 1
LIVEKIT=$(command -v livekit-server || echo tools/livekit-server)

# The address of the interface that carries the default route (Wi-Fi, Ethernet or iPhone hotspot).
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
IP=$(ipconfig getifaddr "${IFACE:-en0}" 2>/dev/null || ipconfig getifaddr en0)
[ -n "$IP" ] || { echo "No network address found. Connect this Mac to the same network as the iPhone."; exit 1; }

# 7880 = LiveKit (WebSocket signalling), 8080 = token server + support page + log endpoint.
for port in 7880 8080; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $port is busy (another run.sh?). Stop it first."; exit 1
  fi
done

echo "Mac: $IP ($IFACE) · support page: http://localhost:8080 · the iOS app finds this Mac automatically"
# --dev uses the devkey/secret pair web/server.mjs signs with; --node-ip makes LiveKit advertise the LAN address to phones.
"$LIVEKIT" --dev --bind 0.0.0.0 --node-ip "$IP" > livekit.log 2>&1 &
LK=$!
# Bonjour announcement; the TXT record host=<IP> is what both apps read to find this Mac.
dns-sd -R "ScreenShare PoC on $(scutil --get ComputerName)" _screensharepoc._tcp local 8080 host="$IP" > /dev/null 2>&1 &
BONJOUR=$!
# Stop LiveKit and the announcement when the Node server exits (e.g. Ctrl+C).
trap 'kill $LK $BONJOUR 2>/dev/null' EXIT
node web/server.mjs
