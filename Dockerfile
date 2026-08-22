FROM alpine:3.22

# Runtime dependencies:
# - bash: script runtime
# - iproute2: ip/bridge utilities used to manage Linux bridges and VXLAN devices
# - jq: JSON configuration parsing and validation
# - docker-cli: creates and validates Docker macvlan networks through docker.sock
# - ca-certificates: standard CA bundle for future integrations/troubleshooting
RUN apk add --no-cache \
    bash \
    iproute2 \
    jq \
    docker-cli \
    ca-certificates

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
