#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-install}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CONFIG="$SCRIPT_DIR/config.json"
GENERATED_DIR="$SCRIPT_DIR/.host-bootstrap"
GENERATED_CONFIG="$GENERATED_DIR/host-config.tsv"
UNIT_NAME="ugreen-vxlan-host-bootstrap.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
DOCKER_DROPIN_DIR="/etc/systemd/system/docker.service.d"
DOCKER_DROPIN="$DOCKER_DROPIN_DIR/10-ugreen-vxlan-host-bootstrap.conf"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this installer as root (for example: sudo ./install.sh $ACTION)"
}

check_project_path() {
    [[ "$SCRIPT_DIR" != *$'\n'* && "$SCRIPT_DIR" != *$'\t'* && "$SCRIPT_DIR" != *' '* ]] || \
        die "Project path must not contain spaces, tabs, or newlines: $SCRIPT_DIR"

    if [[ "$SCRIPT_DIR" != /volume*/* ]]; then
        log "WARNING: project is not under /volumeX/. Keep it on persistent storage before relying on boot-safe mode."
    fi
}

compose() {
    (cd "$SCRIPT_DIR" && docker compose "$@")
}

compose_jq() {
    compose run --rm --no-deps --entrypoint jq vxlan-bootstrap "$@"
}

validate_config() {
    [[ -r "$CONFIG" ]] || die "Config file not readable: $CONFIG"

    log "Validating existing config.json schema"

    compose_jq -e '
      (.global | type == "object") and
      (.global.underlay_interface | type == "string" and length > 0) and
      (.global.local_vtep | type == "string" and length > 0) and
      (.global.remote_vtep | type == "string" and length > 0) and
      ((.global.udp_port // 4789) | type == "number") and
      ((.global.mtu // 1450) | type == "number") and
      (.bridges | type == "array") and
      (.tunnels | type == "array") and
      (.docker_networks | type == "array") and
      (all(.bridges[]; (.name | type == "string" and length > 0))) and
      (all(.tunnels[]; (.name | type == "string" and length > 0) and (.vni | type == "number") and (.bridge | type == "string" and length > 0))) and
      (all(.docker_networks[]; (.name | type == "string" and length > 0) and (.parent | type == "string" and length > 0))) and
      (([.bridges[].name] | length) == ([.bridges[].name] | unique | length)) and
      (([.tunnels[].name] | length) == ([.tunnels[].name] | unique | length)) and
      (([.tunnels[].vni] | length) == ([.tunnels[].vni] | unique | length)) and
      (([.docker_networks[].name] | length) == ([.docker_networks[].name] | unique | length)) and
      ([.bridges[].name] as $bridges | all(.tunnels[]; .bridge as $b | ($bridges | index($b) != null))) and
      ([.bridges[].name] as $bridges | all(.docker_networks[]; .parent as $p | ($bridges | index($p) != null)))
    ' /config/config.json >/dev/null || die "Invalid config.json"
}

render_host_config() {
    local tmp
    mkdir -p "$GENERATED_DIR"
    chmod 0755 "$GENERATED_DIR"
    tmp="$GENERATED_CONFIG.tmp.$$"

    log "Rendering pre-Docker host configuration"

    {
        printf '# ugreen-dxp-vxlan-bootstrap generated host config v1\n'
        printf '# source: %s\n' "$CONFIG"
        compose_jq -r '
          .global as $g |
          "GLOBAL\t\($g.underlay_interface)\t\($g.local_vtep)\t\($g.remote_vtep)\t\($g.udp_port // 4789)\t\($g.mtu // 1450)",
          (.bridges[] |
            "BRIDGE\t\(.name)\t\(.mtu // ($g.mtu // 1450))\t\(if (.multicast_snooping // false) then 1 else 0 end)\t\(if (.stp // false) then 1 else 0 end)"),
          (.tunnels[] |
            "TUNNEL\t\(.name)\t\(.vni)\t\(.bridge)\t\(.local_vtep // $g.local_vtep)\t\(.remote_vtep // $g.remote_vtep)\t\(.udp_port // ($g.udp_port // 4789))\t\(.mtu // ($g.mtu // 1450))")
        ' /config/config.json
    } > "$tmp"

    grep -q $'^GLOBAL\t' "$tmp" || { rm -f "$tmp"; die "Generated host config has no GLOBAL row"; }
    grep -q $'^BRIDGE\t' "$tmp" || log "WARNING: generated host config contains no bridges"
    grep -q $'^TUNNEL\t' "$tmp" || log "WARNING: generated host config contains no VXLAN tunnels"

    chmod 0644 "$tmp"
    mv -f "$tmp" "$GENERATED_CONFIG"
}

write_systemd_files() {
    log "Installing systemd boot dependency"

    cat > "$UNIT_FILE" <<EOF_UNIT
[Unit]
Description=UGREEN DXP VXLAN host bootstrap
Documentation=https://github.com/pi4-dev/ugreen-dxp-vxlan-bootstrap
Wants=network-online.target
After=network-online.target
Before=docker.service
ConditionPathExists=$GENERATED_CONFIG

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_DIR/host-bootstrap.sh apply $GENERATED_CONFIG
ExecReload=/bin/bash $SCRIPT_DIR/host-bootstrap.sh apply $GENERATED_CONFIG
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 0644 "$UNIT_FILE"

    mkdir -p "$DOCKER_DROPIN_DIR"
    cat > "$DOCKER_DROPIN" <<EOF_DROPIN
[Unit]
Requires=$UNIT_NAME
After=$UNIT_NAME
EOF_DROPIN
    chmod 0644 "$DOCKER_DROPIN"

    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null
}

apply_now() {
    log "Applying host bridge/VXLAN state without restarting Docker"
    systemctl restart "$UNIT_NAME"

    log "Starting/reconciling the existing Docker bootstrap container"
    compose up -d --build vxlan-bootstrap

    local i status
    for i in $(seq 1 30); do
        status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' vxlan-bootstrap 2>/dev/null || true)
        case "$status" in
            healthy)
                log "vxlan-bootstrap is healthy"
                return 0
                ;;
            unhealthy)
                docker logs --tail 100 vxlan-bootstrap || true
                die "vxlan-bootstrap became unhealthy"
                ;;
        esac
        sleep 1
    done

    docker logs --tail 100 vxlan-bootstrap || true
    die "vxlan-bootstrap did not become healthy"
}

show_status() {
    echo
    echo "Systemd boot bootstrap:"
    systemctl --no-pager --full status "$UNIT_NAME" 2>/dev/null || true

    echo
    echo "Docker dependency:"
    systemctl show docker.service -p Requires -p After 2>/dev/null || true

    echo
    echo "Generated host configuration:"
    if [[ -r "$GENERATED_CONFIG" ]]; then
        sed -n '1,200p' "$GENERATED_CONFIG"
    else
        echo "MISSING: $GENERATED_CONFIG"
    fi

    echo
    echo "Host network state:"
    if [[ -x "$SCRIPT_DIR/host-bootstrap.sh" && -r "$GENERATED_CONFIG" ]]; then
        "$SCRIPT_DIR/host-bootstrap.sh" status "$GENERATED_CONFIG" || true
    fi

    echo
    echo "Docker bootstrap:"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker inspect --format='container={{.Name}} state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' vxlan-bootstrap 2>/dev/null || echo "vxlan-bootstrap container not found"
    else
        echo "Docker daemon is not available"
    fi
}

uninstall_boot_integration() {
    log "Removing boot-order integration only; runtime VXLAN and Docker networks are left untouched"

    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$DOCKER_DROPIN"
    rmdir "$DOCKER_DROPIN_DIR" 2>/dev/null || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true

    log "Boot-safe integration removed"
    log "If you also want to remove runtime networks, stop dependent workloads and use the existing cleanup action separately."
}

require_root
require_cmd bash
require_cmd systemctl
require_cmd docker
check_project_path

case "$ACTION" in
    install|sync)
        require_cmd grep
        require_cmd sed
        require_cmd seq
        [[ -x "$SCRIPT_DIR/host-bootstrap.sh" ]] || die "Missing executable: $SCRIPT_DIR/host-bootstrap.sh"
        systemctl cat docker.service >/dev/null 2>&1 || die "docker.service was not found in systemd"
        docker info >/dev/null 2>&1 || die "Docker daemon must be running for installation/sync"
        docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

        log "Building the existing bootstrap image so its bundled jq can render config.json"
        compose build vxlan-bootstrap
        validate_config
        render_host_config
        write_systemd_files
        apply_now

        log "Boot-safe VXLAN integration installed successfully"
        log "Docker will require $UNIT_NAME on the next Docker start and on future boots."
        ;;

    status)
        show_status
        ;;

    uninstall)
        uninstall_boot_integration
        ;;

    *)
        die "Unknown action '$ACTION'. Valid actions: install, sync, status, uninstall"
        ;;
esac
