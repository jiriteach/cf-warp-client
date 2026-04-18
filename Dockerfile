FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus \
        gnupg \
        iproute2 \
        iptables \
        iputils-ping \
        lsb-release \
        procps \
        traceroute \
    && install -d -m 0755 /usr/share/keyrings \
    && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/cloudflare-client.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflare-warp \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /run/dbus /var/lib/cloudflare-warp /var/log/cloudflare-warp

VOLUME ["/var/lib/cloudflare-warp", "/var/log/cloudflare-warp"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["status"]
