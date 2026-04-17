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
# Kernel networking — ip_forward and reverse path filtering
# ---------------------------------------------------------------------------
# Enable IP forwarding so the kernel passes packets between interfaces.
# With network_mode: host this sets it on the host network namespace directly.
sysctl -w net.ipv4.ip_forward=1 2>/dev/null \
    || echo "[warn] Could not set ip_forward — ensure it is enabled on the host."

# Disable reverse path filtering globally and per-interface.
# rp_filter=1 (the default) drops packets whose source address is not reachable
# via the interface they arrived on. WARP connector traffic is asymmetric by
# design, so rp_filter will silently drop legitimate return traffic.
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null \
    || echo "[warn] Could not set rp_filter on all."
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null \
    || echo "[warn] Could not set rp_filter on default."

# ---------------------------------------------------------------------------
# iptables — forwarding and masquerade (NAT) rules
# ---------------------------------------------------------------------------
# Allow all forwarded traffic (packets transiting this host between interfaces).
iptables -A FORWARD -j ACCEPT 2>/dev/null \
    || echo "[warn] Could not set FORWARD rule."

# Masquerade outbound traffic so that hosts on the local subnet see the
# connector's own IP as the source, ensuring return traffic routes back
# through the connector rather than trying to reach the WARP peer directly.
iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null \
    || echo "[warn] Could not set MASQUERADE rule."

echo "[info] Routing rules applied."

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
