# UGREEN DXP VXLAN Bootstrap

A small Docker-based bootstrap service for creating persistent, declarative VXLAN connectivity on a UGREEN NASync DXP running UGOS.

The project is intended for environments where Docker containers on the DXP need Layer-2 presence in one or more remote networks, while the DXP host itself **must not have IP addresses in those extended networks**.

## Architecture

```text
                         Central router / VTEP
                              10.10.10.1
                                  |
                    +-------------+-------------+
                    |             |             |
                 VNI 30         VNI 40        VNI 50
                    |             |             |
                   vx30          vx40          vx50
                    |             |             |
                   br30          br40          br50
                    |             |             |
              Docker macvlan Docker macvlan Docker macvlan
                    |             |             |
               containers     containers     containers

DXP host:
  br30/br40/br50 -> no L3 addresses
  vx30/vx40/vx50 -> no L3 addresses

Containers:
  192.168.30.x
  192.168.40.x
  192.168.50.x
```

The DXP participates in the VXLAN **underlay** using its normal host address. The extended LAN addresses exist only inside attached Docker containers.

## Why a bootstrap container?

Linux VXLAN interfaces and custom bridges created with `ip link` are runtime objects. They disappear after a reboot. Keeping the desired state in a Docker project stored on the DXP data volume provides a simple way to reconstruct the networking after a reboot or UGOS upgrade.

The bootstrap container:

1. enters the DXP host network namespace with `network_mode: host`;
2. creates Linux bridges;
3. creates point-to-point VXLAN interfaces to a remote VTEP;
4. attaches each VXLAN interface to the configured bridge;
5. creates Docker macvlan networks using those bridges as parents;
6. keeps running and exposes a Docker healthcheck.

The operation is idempotent: starting it again validates existing resources and recreates missing ones.

## Important design assumptions

- The DXP host has a normal routed underlay address used as the local VXLAN endpoint.
- The remote VXLAN endpoint is normally a central router, firewall, Linux host, or VXLAN-capable switch.
- Multiple VNIs can use the same remote VTEP.
- Each extended L2 domain should normally use one VNI, one VXLAN interface, one Linux bridge, and one Docker macvlan network.
- The DXP bridge interfaces intentionally have no IPv4 or IPv6 addresses from the extended networks.
- Containers connected to macvlan networks are normally unable to communicate directly with the DXP host through that macvlan parent. Give applications a second regular Docker network when host/local-container communication is required.

## Files

```text
.
├── compose.yml
├── config.json
├── Dockerfile
├── entrypoint.sh
├── mikrotik.md
└── README.md
```

## Remote VTEP examples

- [MikroTik RouterOS v7 VXLAN configuration](mikrotik.md) — central VTEP example with multiple VNIs, VLAN mapping, routing, firewall, MTU, verification, and troubleshooting.

## Requirements

- UGREEN DXP / UGOS with Docker and Docker Compose
- SSH access for initial deployment and troubleshooting
- underlay IP reachability between the DXP and remote VTEP
- UDP/4789 allowed between VXLAN endpoints, unless another destination port is configured
- remote VTEP configured with matching VNIs and L2 segments

## Configuration

All desired state is defined in `config.json`.

### Global settings

```json
{
  "global": {
    "underlay_interface": "eth0",
    "local_vtep": "10.10.20.10",
    "remote_vtep": "10.10.10.1",
    "udp_port": 4789,
    "mtu": 1450
  }
}
```

| Field | Description |
|---|---|
| `underlay_interface` | DXP host interface used to reach the remote VTEP. Use the actual UGOS interface name, for example `eth0`, `bond0`, or another host interface. |
| `local_vtep` | DXP underlay IP used as the VXLAN source address. |
| `remote_vtep` | Default remote VXLAN endpoint. Individual tunnels may override it. |
| `udp_port` | VXLAN destination UDP port. Default: `4789`. |
| `mtu` | Default MTU for created bridges and VXLAN devices. `1450` is appropriate for a 1500-byte IPv4 underlay in typical deployments. |

Before deployment, verify the real DXP interface and route:

```bash
ip -br addr
ip route
ip route get 10.10.10.1
```

### Bridges

```json
{
  "name": "br30",
  "mtu": 1450,
  "multicast_snooping": false,
  "stp": false
}
```

The bootstrap service explicitly flushes IPv4 and IPv6 addresses from managed bridges. This is intentional: the DXP must not become an L3 endpoint in the extended networks.

`multicast_snooping: false` is useful for Home Assistant/IoT segments where predictable flooding of mDNS, SSDP, and other multicast traffic is more useful than multicast optimization.

### VXLAN tunnels

```json
{
  "name": "vx30",
  "vni": 30,
  "bridge": "br30"
}
```

A tunnel inherits `local_vtep`, `remote_vtep`, `udp_port`, and `mtu` from `global`.

Any of them can be overridden per tunnel:

```json
{
  "name": "vx60",
  "vni": 60,
  "bridge": "br60",
  "local_vtep": "10.10.20.10",
  "remote_vtep": "10.10.10.2",
  "udp_port": 4789,
  "mtu": 1450
}
```

### Docker macvlan networks

```json
{
  "name": "vxlan-ha",
  "parent": "br30",
  "subnet": "192.168.30.0/24",
  "gateway": "192.168.30.1",
  "ip_range": "192.168.30.192/27"
}
```

`ip_range` is optional. Using a dedicated range is recommended so Docker addresses do not overlap with DHCP pools or statically assigned addresses elsewhere in the LAN.

## Deploy

Choose a persistent directory on the DXP storage pool, for example:

```bash
mkdir -p /volume1/docker/vxlan-bootstrap
cd /volume1/docker/vxlan-bootstrap
```

Copy the repository files there and edit `config.json` for the actual network.

Build the image:

```bash
docker compose build
```

Start the bootstrap service:

```bash
docker compose up -d
```

Follow logs:

```bash
docker logs -f vxlan-bootstrap
```

Expected sequence:

```text
Creating bridge br30
Creating VXLAN vx30: VNI=30 local=10.10.20.10 remote=10.10.10.1 port=4789
Creating Docker macvlan network vxlan-ha parent=br30 subnet=192.168.30.0/24
Configuration applied successfully
Bootstrap container is ready; keeping it alive
```

## Actions

The image supports four actions.

### `apply`

Creates and validates the configured objects. This is the default action used by `docker compose up -d`.

For an explicit one-shot apply:

```bash
docker compose run --rm --no-deps vxlan-bootstrap apply
```

When used as the normal Compose service, `apply` keeps the bootstrap container alive after configuration so Docker can report its health state.

### `status`

Read-only diagnostic output:

```bash
docker compose exec vxlan-bootstrap /entrypoint.sh status
```

or:

```bash
docker compose run --rm --no-deps vxlan-bootstrap status
```

It displays:

- managed Linux bridges and their members;
- detailed VXLAN parameters;
- VXLAN forwarding database entries;
- Docker macvlan network settings;
- containers currently attached to each managed Docker network.

### `healthcheck`

Docker Compose calls this automatically.

Manual test:

```bash
docker compose exec vxlan-bootstrap /entrypoint.sh healthcheck
```

Check Docker health state:

```bash
docker inspect --format='{{.State.Health.Status}}' vxlan-bootstrap
```

Expected result:

```text
healthy
```

### `cleanup`

Safely removes all resources declared in the current `config.json` in reverse dependency order:

```text
Docker macvlan networks
        |
        v
VXLAN interfaces
        |
        v
Linux bridges
```

Stop application containers using the managed networks first. Then stop the resident bootstrap container and run cleanup:

```bash
docker compose stop vxlan-bootstrap

docker compose run --rm --no-deps vxlan-bootstrap cleanup
```

Cleanup performs a preflight before deleting anything. It aborts if:

- a managed Docker network still has attached containers;
- a Docker network with the configured name exists but is not the expected macvlan network;
- a same-named VXLAN device is actually another interface type;
- a same-named bridge is not a Linux bridge;
- a managed bridge contains an undeclared/foreign interface.

Example refusal:

```text
BLOCKED: Docker network 'vxlan-ha' has 1 attached container(s):
  - homeassistant (192.168.30.200/24)
ERROR: Cleanup aborted. No resources were removed.
```

## Changing VNI, VTEP, or other immutable parameters

Do not edit an active tunnel's VNI/VTEP and expect `apply` to silently replace it. The service intentionally treats those changes as conflicts to protect attached workloads.

Use this procedure:

1. stop containers connected to the affected Docker networks;
2. run `cleanup` using the **old** `config.json`;
3. edit `config.json`;
4. start the bootstrap service again.

Example:

```bash
docker compose stop vxlan-bootstrap
docker compose run --rm --no-deps vxlan-bootstrap cleanup
vi config.json
docker compose up -d
```

## Using a VXLAN network from another Compose project

The bootstrap creates Docker networks as standalone/external networks. Other Compose projects must reference them with `external: true`.

Example Home Assistant configuration:

```yaml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped

    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro

    devices:
      - /dev/serial/by-id/YOUR_ZIGBEE_DEVICE:/dev/ttyZIGBEE

    networks:
      services:
      ha_l2:
        ipv4_address: 192.168.30.200

networks:
  services:
    driver: bridge

  ha_l2:
    external: true
    name: vxlan-ha
```

This gives Home Assistant two interfaces:

```text
Home Assistant
   |
   +-- regular Docker bridge -> local services / other containers
   |
   +-- vxlan-ha macvlan -> 192.168.30.200 -> remote L2 network through VXLAN
```

The DXP itself still has no `192.168.30.x` address.

## Startup ordering after DXP reboot

Docker does not provide strict startup ordering across independent Compose projects. A workload referencing an external network cannot start before that network exists.

Recommended boot sequence:

```text
Docker daemon available
        |
        v
vxlan-bootstrap starts
        |
        v
health = healthy
        |
        v
Home Assistant / other dependent stacks start
```

At minimum, configure dependent services so failed starts are retried (`restart: unless-stopped` or an equivalent UGOS startup mechanism). For deterministic startup, use a small host-side launcher or startup task that starts this project first, waits for `healthy`, and then starts dependent Compose projects.

Example logic:

```bash
cd /volume1/docker/vxlan-bootstrap
docker compose up -d

until [ "$(docker inspect --format='{{.State.Health.Status}}' vxlan-bootstrap 2>/dev/null)" = "healthy" ]; do
    sleep 2
done

cd /volume1/docker/homeassistant
docker compose up -d
```

Store such a launcher on the persistent data volume rather than relying on temporary runtime files.

## Verification and troubleshooting

### Verify underlay reachability

```bash
ip route get 10.10.10.1
ping 10.10.10.1
```

### Inspect VXLAN interfaces

```bash
ip -d link show type vxlan
```

### Inspect bridges

```bash
bridge link
bridge fdb show
```

### Verify that DXP has no extended-LAN IP address

```bash
ip addr show br30
```

The bridge should be `UP` but should not contain an `inet 192.168.30.x` address.

### Inspect Docker networks

```bash
docker network inspect vxlan-ha
```

### Capture VXLAN traffic

On the DXP underlay interface:

```bash
tcpdump -ni eth0 udp port 4789
```

### Check multicast/discovery

For Home Assistant and IoT networks, verify that broadcast and multicast traffic traverses the VXLAN. Typical protocols include:

- ARP;
- mDNS (`224.0.0.251:5353`);
- SSDP (`239.255.255.250:1900`).

Example:

```bash
tcpdump -ni br30 'arp or udp port 5353 or udp port 1900'
```

## MTU

VXLAN adds encapsulation overhead. With a standard 1500-byte IPv4 underlay, `1450` is a conservative default for the overlay interfaces.

If the underlay supports jumbo frames, a larger overlay MTU may be used, but it should be validated end-to-end on both VTEPs and every intermediate device.

## Security considerations

The service intentionally has powerful access:

- `network_mode: host` places it in the host network namespace;
- `CAP_NET_ADMIN` allows it to modify host networking;
- `/var/run/docker.sock` allows it to create and remove Docker networks and effectively provides administrative access to the Docker daemon.

Protect the project directory and `config.json`, and do not run untrusted images or scripts with this Compose configuration.

The container is **not** run with full `privileged: true`; only the capability needed for network management is granted.

## Persistence across UGOS upgrades

The Linux bridge and VXLAN runtime objects themselves do not survive a reboot. Persistence is achieved by storing this project on the DXP data volume and re-running the bootstrap after Docker starts.

UGOS upgrades can change Docker or host networking behavior. After an upgrade, verify:

```bash
docker compose up -d
docker inspect --format='{{.State.Health.Status}}' vxlan-bootstrap
docker compose exec vxlan-bootstrap /entrypoint.sh status
```

Because the configuration is declarative and `apply` is idempotent, missing runtime objects are recreated without manually rebuilding every VXLAN interface.

## Remote VTEP configuration

This repository configures only the DXP side. The central router/VTEP must provide matching:

- VNI;
- UDP destination port;
- local/remote VTEP reachability;
- bridge-domain/VLAN mapping;
- MTU;
- forwarding policy/firewall rules.

The exact configuration depends on the remote platform. For MikroTik RouterOS, see [mikrotik.md](mikrotik.md).

## License

No license has been selected yet. Add an explicit license before treating the repository as reusable open-source software.
