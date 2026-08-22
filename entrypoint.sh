#!/usr/bin/env bash

set -euo pipefail

# Path to the declarative configuration. It can be overridden with CONFIG.
CONFIG="${CONFIG:-/config/config.json}"

# Supported actions:
#   apply       - create/validate all declared resources and stay running
#   cleanup     - safely remove all declared Docker networks, VXLANs, bridges
#   status      - print the current state without changing anything
#   healthcheck - exit 0 only if all declared resources exist
ACTION="${1:-apply}"


# ============================================================================
# Logging and generic helpers
# ============================================================================

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}


die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}


require_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}


# Linux interface names are limited to IFNAMSIZ-1 (15 visible characters).
validate_ifname() {
    local name="$1"

    [[ -n "$name" ]] || die "Empty interface name"
    (( ${#name} <= 15 )) ||
        die "Interface name '$name' exceeds Linux 15-character limit"
}


# Return success if the named device is a Linux bridge.
is_bridge() {
    local name="$1"
    [[ -d "/sys/class/net/$name/bridge" ]]
}


# Return success if the named device is a VXLAN interface.
is_vxlan() {
    local name="$1"

    ip -d link show dev "$name" 2>/dev/null |
        grep -qE 'vxlan id [0-9]+'
}


# ============================================================================
# Configuration validation
# ============================================================================

validate_config() {
    [[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"

    # Validate the minimum top-level schema before accessing individual fields.
    jq -e '
      (.global | type == "object") and
      (.global.underlay_interface | type == "string" and length > 0) and
      (.global.local_vtep | type == "string" and length > 0) and
      (.global.remote_vtep | type == "string" and length > 0) and
      (.bridges | type == "array") and
      (.tunnels | type == "array") and
      (.docker_networks | type == "array")
    ' "$CONFIG" >/dev/null || die "Invalid config.json structure"

    local dup

    # Bridge names must be unique.
    dup=$(
        jq -r '
          [.bridges[].name]
          | group_by(.)[]
          | select(length > 1)
          | .[0]
        ' "$CONFIG" |
        head -1
    )
    [[ -z "$dup" ]] || die "Duplicate bridge name in config: $dup"

    # VXLAN interface names must be unique.
    dup=$(
        jq -r '
          [.tunnels[].name]
          | group_by(.)[]
          | select(length > 1)
          | .[0]
        ' "$CONFIG" |
        head -1
    )
    [[ -z "$dup" ]] || die "Duplicate tunnel name in config: $dup"

    # A VNI is treated as unique within this DXP configuration.
    dup=$(
        jq -r '
          [.tunnels[].vni]
          | group_by(.)[]
          | select(length > 1)
          | .[0]
        ' "$CONFIG" |
        head -1
    )
    [[ -z "$dup" ]] || die "Duplicate VNI in config: $dup"

    # Docker network names must be unique.
    dup=$(
        jq -r '
          [.docker_networks[].name]
          | group_by(.)[]
          | select(length > 1)
          | .[0]
        ' "$CONFIG" |
        head -1
    )
    [[ -z "$dup" ]] || die "Duplicate Docker network name in config: $dup"

    # Validate all Linux device names before attempting any changes.
    while read -r name; do
        validate_ifname "$name"
    done < <(
        jq -r '.bridges[].name, .tunnels[].name' "$CONFIG"
    )

    # Every tunnel must reference a bridge declared in the same config.
    while read -r bridge; do
        jq -e \
            --arg bridge "$bridge" \
            '[.bridges[].name] | index($bridge) != null' \
            "$CONFIG" >/dev/null ||
            die "Tunnel references undefined bridge: $bridge"
    done < <(
        jq -r '.tunnels[].bridge' "$CONFIG"
    )

    # Every Docker macvlan network must use a bridge declared in the config.
    while read -r parent; do
        jq -e \
            --arg parent "$parent" \
            '[.bridges[].name] | index($parent) != null' \
            "$CONFIG" >/dev/null ||
            die "Docker network references undefined parent bridge: $parent"
    done < <(
        jq -r '.docker_networks[].parent' "$CONFIG"
    )
}


# ============================================================================
# Global configuration
# ============================================================================

load_globals() {
    UNDERLAY=$(jq -r '.global.underlay_interface' "$CONFIG")
    LOCAL_VTEP=$(jq -r '.global.local_vtep' "$CONFIG")
    REMOTE_VTEP=$(jq -r '.global.remote_vtep' "$CONFIG")
    UDP_PORT=$(jq -r '.global.udp_port // 4789' "$CONFIG")
    DEFAULT_MTU=$(jq -r '.global.mtu // 1450' "$CONFIG")

    validate_ifname "$UNDERLAY"

    ip link show dev "$UNDERLAY" >/dev/null 2>&1 ||
        die "Underlay interface '$UNDERLAY' does not exist"

    # The route check is informational. Advanced routing policies can make a
    # simple route lookup misleading, so this is intentionally not fatal.
    if ! ip route get "$REMOTE_VTEP" 2>/dev/null |
        grep -q "dev $UNDERLAY"; then
        log "WARNING: route to remote VTEP $REMOTE_VTEP does not appear to use $UNDERLAY"
        ip route get "$REMOTE_VTEP" 2>/dev/null || true
    fi
}


# ============================================================================
# Linux bridge management
# ============================================================================

create_bridge() {
    local br="$1"
    local mtu="$2"
    local snoop="$3"
    local stp="$4"

    local snoop_value=1
    local stp_value=1

    [[ "$snoop" == "false" ]] && snoop_value=0
    [[ "$stp" == "false" ]] && stp_value=0

    if ip link show dev "$br" >/dev/null 2>&1; then
        is_bridge "$br" ||
            die "Interface '$br' already exists but is not a Linux bridge"
        log "Bridge $br already exists"
    else
        log "Creating bridge $br"
        ip link add name "$br" type bridge
    fi

    ip link set dev "$br" mtu "$mtu"
    ip link set dev "$br" type bridge \
        mcast_snooping "$snoop_value" \
        stp_state "$stp_value"

    # Design rule: DXP must not own L3 addresses in the extended VXLAN LANs.
    # Only attached Docker containers receive addresses from those subnets.
    # addrgenmode none plus address flushing also prevents an IPv6 link-local
    # address from being left on the bridge by normal kernel autoconfiguration.
    ip link set dev "$br" addrgenmode none 2>/dev/null || true
    ip -4 addr flush dev "$br" 2>/dev/null || true
    ip -6 addr flush dev "$br" 2>/dev/null || true

    ip link set dev "$br" up
}


# ============================================================================
# VXLAN management
# ============================================================================

# Existing VXLAN interfaces are validated instead of silently recreated. This
# prevents a changed VNI/VTEP from unexpectedly cutting off running workloads.
validate_existing_vxlan() {
    local name="$1"
    local vni="$2"
    local local_ip="$3"
    local remote_ip="$4"
    local port="$5"
    local detail

    is_vxlan "$name" ||
        die "Interface '$name' already exists but is not VXLAN"

    detail=$(ip -d link show dev "$name")

    grep -qE "vxlan id ${vni}( |$)" <<<"$detail" ||
        die "VXLAN '$name' exists with different VNI. Run cleanup before changing immutable VXLAN parameters."

    grep -qE "local ${local_ip}( |$)" <<<"$detail" ||
        die "VXLAN '$name' exists with different local VTEP. Run cleanup first."

    grep -qE "remote ${remote_ip}( |$)" <<<"$detail" ||
        die "VXLAN '$name' exists with different remote VTEP. Run cleanup first."

    grep -qE "dstport ${port}( |$)" <<<"$detail" ||
        die "VXLAN '$name' exists with different UDP port. Run cleanup first."
}


create_vxlan() {
    local name="$1"
    local vni="$2"
    local bridge="$3"
    local local_ip="$4"
    local remote_ip="$5"
    local port="$6"
    local mtu="$7"

    is_bridge "$bridge" || die "Bridge '$bridge' does not exist"

    if ip link show dev "$name" >/dev/null 2>&1; then
        validate_existing_vxlan \
            "$name" "$vni" "$local_ip" "$remote_ip" "$port"
        log "VXLAN $name already exists"
    else
        log "Creating VXLAN $name: VNI=$vni local=$local_ip remote=$remote_ip port=$port"
        ip link add "$name" \
            type vxlan \
            id "$vni" \
            dev "$UNDERLAY" \
            local "$local_ip" \
            remote "$remote_ip" \
            dstport "$port"
    fi

    ip link set dev "$name" mtu "$mtu"

    # Attach the VXLAN device to the requested bridge. Re-attach it if the
    # current master differs from the declarative configuration.
    local current_master
    current_master=$(
        basename "$(
            readlink -f "/sys/class/net/$name/master" 2>/dev/null || true
        )"
    )

    if [[ "$current_master" != "$bridge" ]]; then
        if [[ -n "$current_master" && "$current_master" != "." ]]; then
            ip link set dev "$name" nomaster
        fi
        ip link set dev "$name" master "$bridge"
    fi

    ip link set dev "$name" up
}


# ============================================================================
# Docker macvlan network management
# ============================================================================

# If a Docker network with the requested name already exists, validate all
# important immutable properties instead of assuming it is ours.
validate_existing_docker_network() {
    local name="$1"
    local parent="$2"
    local subnet="$3"
    local gateway="$4"
    local ip_range="$5"

    local json
    local driver
    local existing_parent
    local existing_mode
    local existing_subnet
    local existing_gateway
    local existing_range

    json=$(docker network inspect "$name")
    driver=$(jq -r '.[0].Driver // ""' <<<"$json")
    existing_parent=$(jq -r '.[0].Options.parent // ""' <<<"$json")
    existing_mode=$(jq -r '.[0].Options.macvlan_mode // "bridge"' <<<"$json")
    existing_subnet=$(jq -r '.[0].IPAM.Config[0].Subnet // ""' <<<"$json")
    existing_gateway=$(jq -r '.[0].IPAM.Config[0].Gateway // ""' <<<"$json")
    existing_range=$(jq -r '.[0].IPAM.Config[0].IPRange // ""' <<<"$json")

    [[ "$driver" == "macvlan" ]] ||
        die "Docker network '$name' exists but driver=$driver (expected macvlan)"
    [[ "$existing_parent" == "$parent" ]] ||
        die "Docker network '$name' parent=$existing_parent (expected $parent)"
    [[ "$existing_mode" == "bridge" ]] ||
        die "Docker network '$name' macvlan_mode=$existing_mode (expected bridge)"
    [[ "$existing_subnet" == "$subnet" ]] ||
        die "Docker network '$name' subnet=$existing_subnet (expected $subnet)"
    [[ "$existing_gateway" == "$gateway" ]] ||
        die "Docker network '$name' gateway=$existing_gateway (expected $gateway)"
    [[ "$existing_range" == "$ip_range" ]] ||
        die "Docker network '$name' ip_range=$existing_range (expected $ip_range)"
}


create_docker_network() {
    local name="$1"
    local parent="$2"
    local subnet="$3"
    local gateway="$4"
    local ip_range="$5"

    is_bridge "$parent" ||
        die "Docker macvlan parent '$parent' is not an existing Linux bridge"

    if docker network inspect "$name" >/dev/null 2>&1; then
        validate_existing_docker_network \
            "$name" "$parent" "$subnet" "$gateway" "$ip_range"
        log "Docker network $name already exists"
        return
    fi

    log "Creating Docker macvlan network $name parent=$parent subnet=$subnet"

    local args=(
        network create
        --driver macvlan
        --subnet "$subnet"
        --gateway "$gateway"
        --opt "parent=$parent"
        --opt "macvlan_mode=bridge"
    )

    if [[ -n "$ip_range" ]]; then
        args+=(--ip-range "$ip_range")
    fi

    args+=("$name")
    docker "${args[@]}" >/dev/null
}


# ============================================================================
# APPLY
# ============================================================================

apply_config() {
    log "Applying VXLAN configuration"

    # Layer 1: create all Linux bridges first.
    while read -r item; do
        local br mtu snoop stp

        br=$(jq -r '.name' <<<"$item")
        mtu=$(jq -r ".mtu // $DEFAULT_MTU" <<<"$item")
        snoop=$(jq -r '.multicast_snooping // false' <<<"$item")
        stp=$(jq -r '.stp // false' <<<"$item")

        create_bridge "$br" "$mtu" "$snoop" "$stp"
    done < <(
        jq -c '.bridges[]' "$CONFIG"
    )

    # Layer 2: create/validate VXLAN devices and attach them to bridges.
    while read -r item; do
        local name vni bridge local_ip remote_ip port mtu

        name=$(jq -r '.name' <<<"$item")
        vni=$(jq -r '.vni' <<<"$item")
        bridge=$(jq -r '.bridge' <<<"$item")
        local_ip=$(jq -r ".local_vtep // \"$LOCAL_VTEP\"" <<<"$item")
        remote_ip=$(jq -r ".remote_vtep // \"$REMOTE_VTEP\"" <<<"$item")
        port=$(jq -r ".udp_port // $UDP_PORT" <<<"$item")
        mtu=$(jq -r ".mtu // $DEFAULT_MTU" <<<"$item")

        create_vxlan \
            "$name" "$vni" "$bridge" "$local_ip" "$remote_ip" "$port" "$mtu"
    done < <(
        jq -c '.tunnels[]' "$CONFIG"
    )

    # Layer 3: expose each bridge to Docker as an external macvlan network.
    while read -r item; do
        local name parent subnet gateway ip_range

        name=$(jq -r '.name' <<<"$item")
        parent=$(jq -r '.parent' <<<"$item")
        subnet=$(jq -r '.subnet' <<<"$item")
        gateway=$(jq -r '.gateway' <<<"$item")
        ip_range=$(jq -r '.ip_range // ""' <<<"$item")

        create_docker_network \
            "$name" "$parent" "$subnet" "$gateway" "$ip_range"
    done < <(
        jq -c '.docker_networks[]' "$CONFIG"
    )

    log "Configuration applied successfully"
}


# ============================================================================
# CLEANUP preflight
# ============================================================================

# Cleanup is deliberately conservative. The preflight verifies that no Docker
# network is in use, no same-named foreign resource would be deleted, and no
# bridge contains an interface not declared as part of this configuration.
# If any check fails, cleanup aborts before deleting anything.
cleanup_preflight() {
    local blocked=0

    log "Cleanup preflight"

    # Docker networks must exist with the expected driver/parent and contain no
    # attached containers before cleanup is allowed to proceed.
    while read -r item; do
        local name parent attached json driver existing_parent

        name=$(jq -r '.name' <<<"$item")
        parent=$(jq -r '.parent' <<<"$item")

        if docker network inspect "$name" >/dev/null 2>&1; then
            json=$(docker network inspect "$name")
            driver=$(jq -r '.[0].Driver // ""' <<<"$json")
            existing_parent=$(jq -r '.[0].Options.parent // ""' <<<"$json")

            if [[ "$driver" != "macvlan" || "$existing_parent" != "$parent" ]]; then
                log "BLOCKED: Docker network '$name' does not match config; refusing to delete it"
                blocked=1
                continue
            fi

            attached=$(jq -r '.[0].Containers | length' <<<"$json")
            if (( attached > 0 )); then
                log "BLOCKED: Docker network '$name' has $attached attached container(s):"
                jq -r '
                  .[0].Containers[]
                  | "  - " + (.Name // "unknown") + " (" + (.IPv4Address // "no-ip") + ")"
                ' <<<"$json"
                blocked=1
            fi
        fi
    done < <(
        jq -c '.docker_networks[]' "$CONFIG"
    )

    # Refuse to remove a same-named interface unless it is actually VXLAN.
    while read -r item; do
        local name
        name=$(jq -r '.name' <<<"$item")

        if ip link show dev "$name" >/dev/null 2>&1 && ! is_vxlan "$name"; then
            log "BLOCKED: interface '$name' exists but is not VXLAN"
            blocked=1
        fi
    done < <(
        jq -c '.tunnels[]' "$CONFIG"
    )

    # Refuse to remove bridges containing undeclared/foreign interfaces.
    while read -r item; do
        local br member allowed
        br=$(jq -r '.name' <<<"$item")

        if ip link show dev "$br" >/dev/null 2>&1 && ! is_bridge "$br"; then
            log "BLOCKED: interface '$br' exists but is not a Linux bridge"
            blocked=1
            continue
        fi

        if is_bridge "$br"; then
            while read -r member; do
                [[ -n "$member" ]] || continue

                allowed=$(
                    jq -r \
                        --arg br "$br" \
                        --arg member "$member" \
                        '[.tunnels[] | select(.bridge == $br) | .name] | index($member) != null' \
                        "$CONFIG"
                )

                if [[ "$allowed" != "true" ]]; then
                    log "BLOCKED: bridge '$br' contains foreign interface '$member'"
                    blocked=1
                fi
            done < <(
                ip -o link show master "$br" 2>/dev/null |
                    awk -F': ' '{print $2}' |
                    cut -d@ -f1
            )
        fi
    done < <(
        jq -c '.bridges[]' "$CONFIG"
    )

    if (( blocked != 0 )); then
        die "Cleanup aborted. No resources were removed."
    fi
}


# ============================================================================
# CLEANUP
# ============================================================================

cleanup_config() {
    cleanup_preflight

    # Remove in reverse dependency order:
    # Docker network -> VXLAN interface -> Linux bridge.
    log "Removing Docker networks"
    while read -r item; do
        local name
        name=$(jq -r '.name' <<<"$item")

        if docker network inspect "$name" >/dev/null 2>&1; then
            log "Removing Docker network $name"
            docker network rm "$name" >/dev/null
        else
            log "Docker network $name does not exist"
        fi
    done < <(
        jq -c '.docker_networks[]' "$CONFIG"
    )

    log "Removing VXLAN interfaces"
    while read -r item; do
        local name
        name=$(jq -r '.name' <<<"$item")

        if ip link show dev "$name" >/dev/null 2>&1; then
            log "Removing VXLAN $name"
            ip link set dev "$name" down 2>/dev/null || true
            ip link delete dev "$name"
        else
            log "VXLAN $name does not exist"
        fi
    done < <(
        jq -c '.tunnels[]' "$CONFIG"
    )

    log "Removing bridges"
    while read -r item; do
        local br members
        br=$(jq -r '.name' <<<"$item")

        if ip link show dev "$br" >/dev/null 2>&1; then
            members=$(
                ip -o link show master "$br" 2>/dev/null |
                    wc -l |
                    tr -d ' '
            )

            (( members == 0 )) ||
                die "Bridge '$br' still has $members member(s); refusing to delete"

            log "Removing bridge $br"
            ip link set dev "$br" down 2>/dev/null || true
            ip link delete dev "$br" type bridge
        else
            log "Bridge $br does not exist"
        fi
    done < <(
        jq -c '.bridges[]' "$CONFIG"
    )

    log "Cleanup completed successfully"
}


# ============================================================================
# HEALTHCHECK
# ============================================================================

# The healthcheck is intentionally read-only. It checks that all declared
# bridges, VXLAN devices, and Docker networks exist. The more detailed `status`
# action should be used for troubleshooting configuration mismatches.
healthcheck_config() {
    local failed=0

    while read -r br; do
        if ! is_bridge "$br"; then
            log "HEALTHCHECK: missing bridge $br"
            failed=1
        fi
    done < <(
        jq -r '.bridges[].name' "$CONFIG"
    )

    while read -r name; do
        if ! is_vxlan "$name"; then
            log "HEALTHCHECK: missing VXLAN $name"
            failed=1
        fi
    done < <(
        jq -r '.tunnels[].name' "$CONFIG"
    )

    while read -r name; do
        if ! docker network inspect "$name" >/dev/null 2>&1; then
            log "HEALTHCHECK: missing Docker network $name"
            failed=1
        fi
    done < <(
        jq -r '.docker_networks[].name' "$CONFIG"
    )

    (( failed == 0 ))
}


# ============================================================================
# STATUS
# ============================================================================

status_config() {
    echo
    echo "=================================================="
    echo " BRIDGES"
    echo "=================================================="

    while read -r br; do
        if is_bridge "$br"; then
            echo
            echo "[OK] $br"
            ip -br addr show dev "$br"
            ip -o link show master "$br" 2>/dev/null || true
        else
            echo "[MISSING] $br"
        fi
    done < <(
        jq -r '.bridges[].name' "$CONFIG"
    )

    echo
    echo "=================================================="
    echo " VXLAN"
    echo "=================================================="

    while read -r name; do
        if is_vxlan "$name"; then
            echo
            echo "[OK] $name"
            ip -d link show dev "$name"
            echo
            echo "FDB:"
            bridge fdb show dev "$name" 2>/dev/null || true
        else
            echo "[MISSING] $name"
        fi
    done < <(
        jq -r '.tunnels[].name' "$CONFIG"
    )

    echo
    echo "=================================================="
    echo " DOCKER NETWORKS"
    echo "=================================================="

    while read -r name; do
        if docker network inspect "$name" >/dev/null 2>&1; then
            echo
            echo "[OK] $name"
            docker network inspect "$name" |
                jq '
                  .[0]
                  | {
                      Name,
                      Driver,
                      Parent: .Options.parent,
                      Mode: .Options.macvlan_mode,
                      IPAM: .IPAM.Config,
                      Containers: (
                        .Containers
                        | to_entries
                        | map({
                            name: .value.Name,
                            ipv4: .value.IPv4Address,
                            mac: .value.MacAddress
                          })
                      )
                    }
                '
        else
            echo "[MISSING] $name"
        fi
    done < <(
        jq -r '.docker_networks[].name' "$CONFIG"
    )
}


# ============================================================================
# Runtime prerequisites
# ============================================================================

for cmd in \
    bash \
    ip \
    bridge \
    jq \
    docker \
    grep \
    awk \
    cut \
    readlink \
    basename \
    head \
    tail; do
    require_cmd "$cmd"
done


# ============================================================================
# Initialization
# ============================================================================

validate_config
load_globals


# ============================================================================
# Action dispatcher
# ============================================================================

case "$ACTION" in
    apply)
        apply_config
        log "Bootstrap container is ready; keeping it alive"
        exec tail -f /dev/null
        ;;

    cleanup)
        cleanup_config
        ;;

    status)
        status_config
        ;;

    healthcheck)
        healthcheck_config
        ;;

    *)
        die "Unknown action '$ACTION'. Valid actions: apply, cleanup, status, healthcheck"
        ;;
esac
