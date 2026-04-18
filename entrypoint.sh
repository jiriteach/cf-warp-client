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
# Kernel networking
#
# With network_mode: host the container shares the host's network namespace,
# so sysctl writes here take effect on the host directly — no host-level
# configuration of ip_forward or rp_filter is required.
# ---------------------------------------------------------------------------
echo "[info] Applying sysctl settings..."

sysctl -w net.ipv4.ip_forward=1 2>/dev/null \
    || echo "[warn] Could not set ip_forward."

# Disable rp_filter on every existing interface individually.
# The effective value per interface is MAX(conf/all, conf/<iface>), so setting
# conf/all=0 alone is NOT enough — each interface must also be set to 0.
# conf/default=0 ensures any interface created later (e.g. CloudflareWARP)
# inherits 0 without needing a separate post-connect step.
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
for iface in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$iface" 2>/dev/null || true
done

echo "[info] sysctl settings applied."

# ---------------------------------------------------------------------------
# iptables — forwarding and masquerade rules
#
# Rules are inserted at position 1 (-I) so they sit above Docker's own
# FORWARD DROP policy rules rather than below them (-A append).
# Each rule is checked with -C first so restarts don't create duplicates.
# ---------------------------------------------------------------------------
echo "[info] Applying iptables rules..."

if ! iptables -C FORWARD -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -j ACCEPT
fi

# MASQUERADE rewrites the source IP of forwarded packets to the connector's
# LAN IP, so local subnet hosts send return traffic back to the connector
# rather than directly to the unreachable WARP peer address.
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

# ---------------------------------------------------------------------------
# rp_filter keeper
#
# Docker daemon writes net.ipv4.conf.all.rp_filter=2 whenever it manages its
# bridge networks. Because the effective rp_filter per interface is
# MAX(conf/all, conf/<iface>), all=2 overrides any per-interface setting of 0.
# This keeper re-applies 0 every 5 seconds so Docker's resets are corrected
# before they can drop traffic. privileged: true in compose ensures the writes
# are not blocked by capability or seccomp restrictions.
# ---------------------------------------------------------------------------
(
    LAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    echo "[rp_filter-keeper] Starting. LAN interface: ${LAN_IFACE:-unknown}"
    while true; do
        echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter     2>/dev/null || true
        echo 0 > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || true
        if [ -n "$LAN_IFACE" ] && [ -f "/proc/sys/net/ipv4/conf/${LAN_IFACE}/rp_filter" ]; then
            echo 0 > "/proc/sys/net/ipv4/conf/${LAN_IFACE}/rp_filter" 2>/dev/null || true
        fi
        if [ -f /proc/sys/net/ipv4/conf/CloudflareWARP/rp_filter ]; then
            echo 0 > /proc/sys/net/ipv4/conf/CloudflareWARP/rp_filter 2>/dev/null || true
        fi
        sleep 5
    done
) &

# ---------------------------------------------------------------------------
# Connectivity watchdog
#
# Docker only auto-restarts a container when it exits — not when it is marked
# unhealthy. This background loop monitors WARP connectivity every 30 seconds
# and kills warp-svc if the tunnel goes down, causing the container to exit
# and Docker's restart: unless-stopped policy to bring it back up cleanly.
# ---------------------------------------------------------------------------
(
    # Allow time for the tunnel to fully establish before monitoring starts
    sleep 90
    echo "[watchdog] Connectivity monitoring started."
    FAIL_COUNT=0
    while true; do
        sleep 30
        if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
            FAIL_COUNT=0
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "[watchdog] Connectivity check failed (${FAIL_COUNT}/3)."
            if [ "$FAIL_COUNT" -ge 3 ]; then
                echo "[watchdog] WARP tunnel down — triggering container restart."
                kill "$WARP_SVC_PID"
                break
            fi
        fi
    done
) &

# Keep the container alive — exit if warp-svc dies
wait $WARP_SVC_PID
