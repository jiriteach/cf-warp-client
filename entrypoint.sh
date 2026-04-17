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
sysctl -w net.ipv4.ip_forward=1 2>/dev/null \
    || echo "[warn] Could not set ip_forward — ensure it is enabled on the host."

# rp_filter must be disabled on ALL existing interfaces individually, not just
# 'all' and 'default'. The effective value per interface is MAX(all, <iface>),
# so setting 'all'=0 alone is not enough if the interface itself is still 1.
# 'default' only applies to interfaces created AFTER this point (e.g. CloudflareWARP).
echo "[info] Disabling rp_filter on all interfaces..."
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
for iface in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$iface" 2>/dev/null || true
done
echo "[info] rp_filter disabled."

# ---------------------------------------------------------------------------
# iptables — forwarding and masquerade (NAT) rules
#
# Docker sets the FORWARD chain policy to DROP and prepends its own rules.
# Using -A (append) means our ACCEPT lands after Docker's rules and may never
# be reached for new connections. We use -I (insert) at position 1 to place
# our rules at the very top of the chain so they are evaluated first.
#
# Rules are checked for existence with -C before adding to stay idempotent
# across container restarts (with network_mode: host, rules survive in the
# host's iptables between stop/start cycles).
# ---------------------------------------------------------------------------
echo "[info] Applying iptables rules..."

# Allow all forwarded traffic — inserted at position 1 so it precedes Docker's DROP
if ! iptables -C FORWARD -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -j ACCEPT
fi

# Masquerade all outbound traffic so local subnet hosts reply to the connector's
# LAN IP rather than the unreachable WARP peer IP — fixing return traffic routing.
if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
    iptables -t nat -I POSTROUTING 1 -j MASQUERADE
fi

echo "[info] iptables rules applied."

# ---------------------------------------------------------------------------
# Start D-Bus system daemon (warp-svc requires it for IPC)
# ---------------------------------------------------------------------------
echo "[info] Starting dbus..."
mkdir -p /run/dbus
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

# ---------------------------------------------------------------------------
# Post-connect: disable rp_filter on the CloudflareWARP tunnel interface.
# The interface is created by warp-svc after connect and won't exist earlier,
# so 'default'=0 above ensures it inherits 0, but we set it explicitly too.
# ---------------------------------------------------------------------------
echo "[info] Waiting for CloudflareWARP interface..."
for i in $(seq 1 15); do
    if [ -d /proc/sys/net/ipv4/conf/CloudflareWARP ]; then
        sysctl -w net.ipv4.conf.CloudflareWARP.rp_filter=0 2>/dev/null || true
        echo "[info] rp_filter disabled on CloudflareWARP."
        break
    fi
    sleep 1
done

echo "[info] WARP mesh connector is up and running."

# Keep the container alive — exit if warp-svc dies
wait $WARP_SVC_PID
