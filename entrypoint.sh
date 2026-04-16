#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Ensure the TUN device node exists (required for WARP tunnel interface)
# ---------------------------------------------------------------------------
if [ ! -c /dev/net/tun ]; then
    echo "[info] Creating /dev/net/tun device node..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi
echo "[info] TUN device ready."

# ---------------------------------------------------------------------------
# Enable IP forwarding (required for mesh/connector routing)
# Note: the host sysctl net.ipv4.ip_forward=1 must also be set, OR the
# container must run with --privileged / the sysctl set in docker-compose.
# ---------------------------------------------------------------------------
sysctl -w net.ipv4.ip_forward=1 2>/dev/null \
    || echo "[warn] Could not set ip_forward via sysctl — ensure it is enabled on the host or via docker-compose sysctls."

# ---------------------------------------------------------------------------
# Start D-Bus system daemon (warp-svc requires it for IPC)
# ---------------------------------------------------------------------------
echo "[info] Starting dbus..."
mkdir -p /run/dbus
# Remove stale pid file left over from a previous container stop
rm -f /run/dbus/pid
dbus-daemon --system --fork
echo "[info] dbus started."

# ---------------------------------------------------------------------------
# Start the WARP background service
# ---------------------------------------------------------------------------
echo "[info] Starting warp-svc..."
warp-svc &
WARP_SVC_PID=$!

# Give the daemon time to initialise its socket
echo "[info] Waiting for warp-svc to become ready..."
for i in $(seq 1 30); do
    if warp-cli --accept-tos status &>/dev/null; then
        echo "[info] warp-svc is ready."
        break
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Register connector (idempotent — skipped if already registered)
# ---------------------------------------------------------------------------
if [ -z "$CONNECTOR_TOKEN" ]; then
    echo "[error] CONNECTOR_TOKEN environment variable is not set. Exiting."
    exit 1
fi

STATUS=$(warp-cli --accept-tos status 2>&1 || true)

if echo "$STATUS" | grep -q "Registration Missing"; then
    echo "[info] Registering WARP connector..."
    warp-cli --accept-tos connector new "$CONNECTOR_TOKEN"
else
    echo "[info] WARP connector already registered — skipping registration."
fi

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
echo "[info] Connecting..."
warp-cli --accept-tos connect

echo "[info] WARP mesh connector is up and running."

# Keep the container alive — exit if warp-svc dies
wait $WARP_SVC_PID
