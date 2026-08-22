#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-apply}"
HOST_CONFIG="${2:-${HOST_CONFIG:-}}"

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

validate_ifname() {
    local name="$1"
    [[ -n "$name" ]] || die "Empty interface name"
    (( ${#name} <= 15 )) || die "Interface name '$name' exceeds Linux 15-character limit"
    [[ "$name" != *$'\t'* && "$name" != *$'\n'* ]] || die "Invalid interface name '$name'"
}

is_bridge() {
    local name="$1"
    [[ -d "/sys/class/net/$name/bridge" ]]
}

is_vxlan() {
    local name="$1"
    ip -d link show dev "$name" 2>/dev/null | grep -qE 'vxlan id [0-9]+'
}

bool01() {
    case "$1" in
        0|1) printf '%s\n' "$1" ;;
        *) die "Expected 0 or 1, got '$1'" ;;
    esac
}

load_global() {
    local kind underlay local_vtep remote_vtep udp_port mtu extra
    local found=0

    while IFS=$'\t' read -r kind underlay local_vtep remote_vtep udp_port mtu extra; do
        [[ -n "$kind" ]] || continue
        [[ "$kind" == \#* ]] && continue

        if [[ "$kind" == "GLOBAL" ]]; then
            (( found == 0 )) || die "Generated host config contains more than one GLOBAL row"
            [[ -z "${extra:-}" ]] || die "Malformed GLOBAL row in $HOST_CONFIG"

            UNDERLAY="$underlay"
            LOCAL_VTEP="$local_vtep"
            REMOTE_VTEP="$remote_vtep"
            UDP_PORT="$udp_port"
            DEFAULT_MTU="$mtu"
            found=1
        fi
    done < "$HOST_CONFIG"

    (( found == 1 )) || die "Generated host config contains no GLOBAL row"

    validate_ifname "$UNDERLAY"
    [[ "$UDP_PORT" =~ ^[0-9]+$ ]] || die "Invalid UDP port '$UDP_PORT'"
    [[ "$DEFAULT_MTU" =~ ^[0-9]+$ ]] || die "Invalid MTU '$DEFAULT_MTU'"

    ip link show dev "$UNDERLAY" >/dev/null 2>&1 || die "Underlay interface '$UNDERLAY' does not exist"

    if ! ip route get "$REMOTE_VTEP" 2>/dev/null | grep -q "dev $UNDERLAY"; then
        log "WARNING: route to remote VTEP $REMOTE_VTEP does not appear to use $UNDERLAY"
        ip route get "$REMOTE_VTEP" 2>/dev/null || true
    fi
}

create_bridge() {
    local br="$1"
    local mtu="$2"
    local snoop="$3"
    local stp="$4"

    validate_ifname "$br"
    [[ "$mtu" =~ ^[0-9]+$ ]] || die "Invalid MTU '$mtu' for bridge $br"
    snoop=$(bool01 "$snoop")
    stp=$(bool01 "$stp")

    if ip link show dev "$br" >/dev/null 2>&1; then
        is_bridge "$br" || die "Interface '$br' already exists but is not a Linux bridge"
        log "Bridge $br already exists"
    else
        log "Creating bridge $br"
        ip link add name "$br" type bridge
    fi

    ip link set dev "$br" mtu "$mtu"
    ip link set dev "$br" type bridge mcast_snooping "$snoop" stp_state "$stp"

    # The DXP is intentionally not an L3 endpoint in the stretched networks.
    ip link set dev "$br" addrgenmode none 2>/dev/null || true
    ip -4 addr flush dev "$br" 2>/dev/null || true
    ip -6 addr flush dev "$br" 2>/dev/null || true
    ip link set dev "$br" up
}

validate_existing_vxlan() {
    local name="$1"
    local vni="$2"
    local local_ip="$3"
    local remote_ip="$4"
    local port="$5"
    local underlay="$6"
    local detail

    is_vxlan "$name" || die "Interface '$name' already exists but is not VXLAN"
    detail=$(ip -d link show dev "$name")

    grep -qE "vxlan id ${vni}( |$)" <<<"$detail" || die "VXLAN '$name' exists with a different VNI"
    grep -qE "local ${local_ip}( |$)" <<<"$detail" || die "VXLAN '$name' exists with a different local VTEP"
    grep -qE "remote ${remote_ip}( |$)" <<<"$detail" || die "VXLAN '$name' exists with a different remote VTEP"
    grep -qE "dstport ${port}( |$)" <<<"$detail" || die "VXLAN '$name' exists with a different UDP port"
    grep -qE "dev ${underlay}( |$)" <<<"$detail" || die "VXLAN '$name' exists on a different underlay interface"
}

create_vxlan() {
    local name="$1"
    local vni="$2"
    local bridge_name="$3"
    local local_ip="$4"
    local remote_ip="$5"
    local port="$6"
    local mtu="$7"
    local current_master

    validate_ifname "$name"
    validate_ifname "$bridge_name"
    [[ "$vni" =~ ^[0-9]+$ ]] || die "Invalid VNI '$vni' for $name"
    [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid UDP port '$port' for $name"
    [[ "$mtu" =~ ^[0-9]+$ ]] || die "Invalid MTU '$mtu' for $name"
    is_bridge "$bridge_name" || die "Bridge '$bridge_name' does not exist"

    if ip link show dev "$name" >/dev/null 2>&1; then
        validate_existing_vxlan "$name" "$vni" "$local_ip" "$remote_ip" "$port" "$UNDERLAY"
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

    current_master=$(basename "$(readlink -f "/sys/class/net/$name/master" 2>/dev/null || true)")
    if [[ "$current_master" != "$bridge_name" ]]; then
        if [[ -n "$current_master" && "$current_master" != "." ]]; then
            ip link set dev "$name" nomaster
        fi
        ip link set dev "$name" master "$bridge_name"
    fi

    ip link set dev "$name" up
}

apply_config() {
    local kind a b c d e f g extra

    log "Applying boot-safe host networking from $HOST_CONFIG"

    while IFS=$'\t' read -r kind a b c d e f g extra; do
        [[ "$kind" == "BRIDGE" ]] || continue
        [[ -z "${e:-}${f:-}${g:-}${extra:-}" ]] || die "Malformed BRIDGE row for '$a'"
        create_bridge "$a" "$b" "$c" "$d"
    done < "$HOST_CONFIG"

    while IFS=$'\t' read -r kind a b c d e f g extra; do
        [[ "$kind" == "TUNNEL" ]] || continue
        [[ -z "${extra:-}" ]] || die "Malformed TUNNEL row for '$a'"
        create_vxlan "$a" "$b" "$c" "$d" "$e" "$f" "$g"
    done < "$HOST_CONFIG"

    log "Boot-safe host networking is ready"
}

status_config() {
    local kind a b c d e f g extra
    local failed=0

    printf '\n%-16s %-10s %-8s %-8s\n' "RESOURCE" "TYPE" "STATE" "MASTER"
    printf '%-16s %-10s %-8s %-8s\n' "----------------" "----------" "--------" "--------"

    while IFS=$'\t' read -r kind a b c d e f g extra; do
        case "$kind" in
            BRIDGE)
                if is_bridge "$a"; then
                    printf '%-16s %-10s %-8s %-8s\n' "$a" "bridge" "OK" "-"
                else
                    printf '%-16s %-10s %-8s %-8s\n' "$a" "bridge" "MISSING" "-"
                    failed=1
                fi
                ;;
            TUNNEL)
                if is_vxlan "$a"; then
                    local master
                    master=$(basename "$(readlink -f "/sys/class/net/$a/master" 2>/dev/null || true)")
                    printf '%-16s %-10s %-8s %-8s\n' "$a" "vxlan" "OK" "${master:-?}"
                    [[ "$master" == "$c" ]] || failed=1
                else
                    printf '%-16s %-10s %-8s %-8s\n' "$a" "vxlan" "MISSING" "-"
                    failed=1
                fi
                ;;
        esac
    done < "$HOST_CONFIG"

    return "$failed"
}

for cmd in bash ip bridge grep awk readlink basename; do
    require_cmd "$cmd"
done

[[ -n "$HOST_CONFIG" ]] || die "Host config path not supplied. Usage: $0 <apply|status> <generated-host-config>"
[[ -r "$HOST_CONFIG" ]] || die "Generated host config not readable: $HOST_CONFIG"

load_global

case "$ACTION" in
    apply)
        apply_config
        ;;
    status)
        status_config
        ;;
    *)
        die "Unknown action '$ACTION'. Valid actions: apply, status"
        ;;
esac
