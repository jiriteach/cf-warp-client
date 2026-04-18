# Cloudflare WARP CLI Container

This image packages the Linux `cloudflare-warp` client for running a Cloudflare Mesh node inside a container.

It is designed for:

- headless `warp-cli` connector enrollment
- plain node connectivity by default
- optional subnet routing through the container
- optional routed return traffic by enabling forwarding and disabling reverse path filtering
- network troubleshooting with `ping` and `traceroute`

## What is included

- Ubuntu 24.04 base image
- `cloudflare-warp`
- `ping`, `traceroute`, `iproute2`, `iptables`, `procps`
- an entrypoint that:
  - starts `warp-svc`
  - streams `warp-svc` logs into `docker logs`
  - optionally enables IPv4 forwarding for subnet routing
  - optionally disables `rp_filter` to avoid dropping asymmetric return traffic
  - optionally accepts forwarded traffic in the `FORWARD` chain
  - optionally runs `warp-cli connector new <TOKEN>`
  - optionally runs `warp-cli connect`
  - periodically logs `warp-cli status` changes

## Files

- [Dockerfile](/Users/jxs/Downloads/cf-warp-cli/Dockerfile)
- [docker/entrypoint.sh](/Users/jxs/Downloads/cf-warp-cli/docker/entrypoint.sh)
- [docker-compose.yml](/Users/jxs/Downloads/cf-warp-cli/docker-compose.yml)

## Build

```bash
docker compose build
```

## Run

Set your connector token first:

```bash
export WARP_CONNECTOR_TOKEN='your-cloudflare-mesh-token'
```

By default the container behaves like a WARP Mesh node and does not enable subnet forwarding.

To turn on subnet routing and reverse-path handling, set:

```bash
export WARP_ENABLE_SUBNET_ROUTING=true
```

If subnet routing is enabled and you are using `network_mode: host`, apply the routing sysctls on the Docker host before starting the container:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.all.forwarding=1
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.default.rp_filter=0
```

Then start the container:

```bash
docker compose up -d
```

If you want to manage forwarding policy outside the container, set:

```bash
export WARP_MANAGE_FORWARD_CHAIN=false
```

`WARP_MANAGE_FORWARD_CHAIN` only matters when `WARP_ENABLE_SUBNET_ROUTING=true`.

The container also supports periodic status logging. The default interval is 15 seconds, and only changed status snapshots are emitted:

```bash
export WARP_STATUS_INTERVAL_SECONDS=15
```

## Important runtime requirements

Use:

- `network_mode: host`
- `cap_add: [NET_ADMIN]`
- `/dev/net/tun`
- persisted `/var/lib/cloudflare-warp`

`host` networking is the safest default here because the WARP client manages low-level routing and tunnel interfaces. Running behind Docker bridge NAT is possible in some setups, but it is usually the wrong fit for a routed mesh gateway.

With `host` networking, Docker Compose cannot apply network `sysctls` for the container. Set those on the host instead, or let the entrypoint attempt them if your runtime permits writing `/proc/sys` from inside the container.

## Verifying

```bash
docker exec -it cf-warp-cli warp-cli --accept-tos status
docker exec -it cf-warp-cli warp-cli --accept-tos registration show
docker exec -it cf-warp-cli ping -c 3 1.1.1.1
docker exec -it cf-warp-cli traceroute 1.1.1.1
```

## Routing notes

When `WARP_ENABLE_SUBNET_ROUTING=false`, this container just joins Mesh as a node and does not try to route third-party subnet traffic.

When `WARP_ENABLE_SUBNET_ROUTING=true`, the surrounding network must send the target CIDR back through this container's host. The container enables forwarding and avoids reverse path filtering drops, but upstream route tables still need to point the advertised subnet toward the Docker host running this container.

If this is deployed in a cloud VPC, also make sure the instance or VM is allowed to forward traffic and that any source/destination checking is disabled where required by the platform.

## Sources

- Cloudflare package install instructions: [pkg.cloudflareclient.com](https://pkg.cloudflareclient.com/)
- Cloudflare Mesh getting started: [Get started with Cloudflare Mesh](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/)
- Cloudflare Mesh overview: [Connect with Cloudflare Mesh](https://developers.cloudflare.com/learning-paths/replace-vpn/connect-private-network/cloudflare-mesh/)
- Cloudflare routing guidance: [Tips and best practices](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/private-net/warp-connector/tips/)

## CLI compatibility note

Recent Cloudflare WARP releases removed some deprecated `warp-cli` commands. In current releases, use `warp-cli registration show` instead of older `warp-cli account` workflows.
