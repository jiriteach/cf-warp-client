# Cloudflare WARP CLI Container

This repository builds a containerized Linux `warp-cli` client suitable for Cloudflare Mesh / WARP Connector style deployments.

The container is configured to run on Docker's default bridge network only.

The image installs:

- `cloudflare-warp`
- `dbus`
- `iputils-ping`
- `traceroute`
- supporting tools such as `curl`, `procps`, `iproute2`, and `tini`

## Files

- `Dockerfile` builds the Ubuntu 24.04 based image
- `docker/entrypoint.sh` starts `dbus`, starts `warp-svc`, enrolls the connector, and connects it
- `docker-compose.yml` provides a ready-to-run example with the required privileges

## Build

```bash
docker build -t cf-warp-cli .
```

## Run with Docker

This container needs Linux networking features that are normally only available on a Linux host or Linux VM.

```bash
docker run -d \
  --name warp-cli \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  -e WARP_CONNECTOR_TOKEN='YOUR_CONNECTOR_TOKEN' \
  -v warp-state:/var/lib/cloudflare-warp \
  cf-warp-cli
```

## Run with Compose

```bash
export WARP_CONNECTOR_TOKEN='YOUR_CONNECTOR_TOKEN'
docker compose up -d --build
```

Compose uses bridge networking by default, and the included `docker-compose.yml` keeps that default.

## Behavior

On startup the entrypoint will:

1. Start the system `dbus-daemon`
2. Start `warp-svc`
3. Run `warp-cli connector new <token>` if the container is not already registered
4. Run `warp-cli connect`
5. Keep the container alive by waiting on `warp-svc`

The WARP state is persisted in `/var/lib/cloudflare-warp`, so reusing the named volume avoids re-enrollment on each restart.

## Useful environment variables

- `WARP_CONNECTOR_TOKEN`: required for first-time connector enrollment
- `WARP_AUTO_CONNECT`: defaults to `true`
- `WARP_WAIT_FOR_CONNECT`: defaults to `true`

## Notes

- Cloudflare’s current docs state Mesh nodes can run on Linux servers, VMs, and containers.
- This repo is set up for bridge mode only. Do not run it with `--network host` or `network_mode: host`.
- The container still requires `NET_ADMIN`, `NET_RAW`, `/dev/net/tun`, and `net.ipv4.ip_forward=1`.
- In bridge mode, the mesh node runs from the container namespace rather than directly on the host network.
