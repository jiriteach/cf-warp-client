#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log_command_output() {
  local prefix="$1"

  while IFS= read -r line; do
    log "${prefix}${line}"
  done
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log "This container must run as root."
    exit 1
  fi
}

check_tun() {
  if [[ ! -c /dev/net/tun ]]; then
    log "/dev/net/tun is missing. Start the container with --device=/dev/net/tun."
    exit 1
  fi
}

set_sysctl_if_present() {
  local key="$1"
  local value="$2"
  local path="/proc/sys/${key//./\/}"

  if [[ -w "$path" ]]; then
    printf '%s' "$value" > "$path"
    log "Set ${key}=${value}"
  else
    log "Unable to set ${key}; ensure the matching sysctl is allowed at container runtime."
  fi
}

configure_forwarding() {
  set_sysctl_if_present net.ipv4.ip_forward 1
  set_sysctl_if_present net.ipv4.conf.all.forwarding 1

  # Disable reverse path filtering so routed return traffic is not dropped.
  set_sysctl_if_present net.ipv4.conf.all.rp_filter 0
  set_sysctl_if_present net.ipv4.conf.default.rp_filter 0
}

configure_firewall() {
  local manage_forward_chain="${WARP_MANAGE_FORWARD_CHAIN:-true}"

  case "${manage_forward_chain,,}" in
    1|true|yes|on) ;;
    *)
      log "WARP_MANAGE_FORWARD_CHAIN is disabled; leaving iptables FORWARD chain unchanged"
      return 0
      ;;
  esac

  if command -v iptables >/dev/null 2>&1; then
    iptables -C FORWARD -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -j ACCEPT
    log "Ensured FORWARD chain accepts forwarded packets"
  fi
}

start_warp_service() {
  : > /var/log/cloudflare-warp/warp-svc.stdout.log
  log "Starting warp-svc"
  warp-svc > /var/log/cloudflare-warp/warp-svc.stdout.log 2>&1 &
  WARP_SVC_PID=$!
  tail -n 0 -F /var/log/cloudflare-warp/warp-svc.stdout.log | log_command_output "[warp-svc] " &
  WARP_LOG_TAIL_PID=$!
}

wait_for_cli() {
  local retries="${WARP_START_TIMEOUT_SECONDS:-30}"
  local i

  for ((i = 0; i < retries; i++)); do
    if warp-cli --accept-tos status >/dev/null 2>&1; then
      log "warp-cli is ready"
      return 0
    fi
    sleep 1
  done

  log "warp-cli did not become ready within ${retries}s"
  return 1
}

enroll_connector_if_requested() {
  local token="${WARP_CONNECTOR_TOKEN:-}"

  if [[ -z "$token" ]]; then
    log "WARP_CONNECTOR_TOKEN not set; skipping connector enrollment"
    return 0
  fi

  if [[ -f /var/lib/cloudflare-warp/.connector-enrolled ]]; then
    log "Connector is already enrolled; reusing persisted state"
    return 0
  fi

  log "Enrolling connector"
  warp-cli --accept-tos connector new "$token" 2>&1 | log_command_output "[warp-cli] "
  touch /var/lib/cloudflare-warp/.connector-enrolled
}

connect_if_requested() {
  local autoconnect="${WARP_AUTOCONNECT:-true}"

  case "${autoconnect,,}" in
    1|true|yes|on)
      log "Connecting WARP"
      warp-cli --accept-tos connect 2>&1 | log_command_output "[warp-cli] "
      ;;
    *)
      log "WARP_AUTOCONNECT is disabled; leaving the client disconnected"
      ;;
  esac
}

status_snapshot() {
  warp-cli --accept-tos status 2>/dev/null || true
}

start_status_reporter() {
  local interval="${WARP_STATUS_INTERVAL_SECONDS:-15}"

  case "${interval}" in
    ''|0)
      log "WARP_STATUS_INTERVAL_SECONDS is disabled; not starting periodic status logging"
      return 0
      ;;
  esac

  (
    local previous=""
    local current=""

    while kill -0 "${WARP_SVC_PID}" 2>/dev/null; do
      current="$(status_snapshot)"
      if [[ -n "${current}" && "${current}" != "${previous}" ]]; then
        while IFS= read -r line; do
          [[ -n "${line}" ]] || continue
          log "[warp-status] ${line}"
        done <<< "${current}"
        previous="${current}"
      fi
      sleep "${interval}"
    done
  ) &
  WARP_STATUS_PID=$!
  log "Started periodic WARP status reporter with ${interval}s interval"
}

print_status() {
  if warp-cli --accept-tos registration show >/dev/null 2>&1; then
    warp-cli --accept-tos registration show 2>&1 | log_command_output "[warp-registration] "
  elif warp-cli --accept-tos registration >/dev/null 2>&1; then
    warp-cli --accept-tos registration 2>&1 | log_command_output "[warp-registration] "
  fi

  warp-cli --accept-tos status 2>&1 | log_command_output "[warp-status] "
}

cleanup() {
  log "Stopping background processes"
  kill -TERM "${WARP_STATUS_PID:-}" 2>/dev/null || true
  kill -TERM "${WARP_LOG_TAIL_PID:-}" 2>/dev/null || true
  kill -TERM "${WARP_SVC_PID:-}" 2>/dev/null || true
  wait "${WARP_STATUS_PID:-}" 2>/dev/null || true
  wait "${WARP_LOG_TAIL_PID:-}" 2>/dev/null || true
  wait "${WARP_SVC_PID:-}" 2>/dev/null || true
}

forward_signals() {
  trap 'cleanup; exit 0' TERM INT
}

run_mode() {
  case "${1:-status}" in
    status)
      print_status
      wait "${WARP_SVC_PID}"
      ;;
    shell)
      shift
      if [[ "$#" -eq 0 ]]; then
        exec /bin/bash
      fi
      exec "$@"
      ;;
    connect)
      warp-cli --accept-tos connect
      print_status
      wait "${WARP_SVC_PID}"
      ;;
    *)
      exec "$@"
      ;;
  esac
}

main() {
  require_root
  check_tun
  configure_forwarding
  configure_firewall
  start_warp_service
  forward_signals
  wait_for_cli
  enroll_connector_if_requested
  connect_if_requested
  start_status_reporter
  run_mode "$@"
}

main "$@"
