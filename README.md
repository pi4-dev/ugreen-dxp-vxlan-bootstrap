# UGREEN DXP VXLAN Bootstrap

Declarative VXLAN connectivity for UGREEN NASync DXP / UGOS, designed to extend remote Layer-2 networks to Docker workloads without assigning overlay IP addresses to the DXP host itself.

The repository supports **two deployment methods** using the same `config.json` format.

## Choose a deployment method

| Method | Best for | Startup behavior | Documentation |
|---|---|---|---|
| **Docker-only bootstrap** | Simple deployments, testing, manual startup, environments where strict boot ordering is not required | Docker starts first; the `vxlan-bootstrap` container creates Linux bridges, VXLAN interfaces and Docker macvlan networks | [container-bootstrap.md](container-bootstrap.md) |
| **Boot-safe systemd + Docker bootstrap** | Production-like homelab use, containers with `restart: unless-stopped`, VM/network dependencies, deterministic reboot behavior | Linux bridges and VXLAN interfaces are created **before `docker.service`**; the container then reconciles Docker networks after Docker starts | [boot-safe.md](boot-safe.md) |

### Recommended method

For a DXP where application containers depend on VXLAN-backed Docker networks, use the **boot-safe method**:

```bash
sudo ./install.sh install
```

This installs a small host-side systemd bootstrap and a Docker service dependency so the required Linux networking exists before Docker restores dependent containers.

The Docker-only method remains fully supported and is useful when you prefer not to modify host systemd configuration.

## Shared architecture

Both methods use the same logical network model:

```text
                     Remote router / VTEP
                              |
                           VXLAN
                              |
                    +---------+---------+
                    |                   |
                 vx30/vx40/...      additional VNIs
                    |
                 br30/br40/...
                    |
          +---------+----------+
          |                    |
   Docker macvlan          VM TAP/bridge
          |                    |
      containers               VM
```

The DXP uses its normal underlay IP as the VXLAN endpoint. Managed overlay bridges intentionally do not receive IP addresses from the extended LANs.

## Configuration

Both deployment methods use the same `config.json` structure:

- `global` — underlay interface, local/remote VTEP, VXLAN UDP port and default MTU;
- `bridges` — Linux bridges created on the DXP;
- `tunnels` — VXLAN interfaces and their bridge associations;
- `docker_networks` — Docker macvlan networks backed by the Linux bridges.

Example:

```json
{
  "global": {
    "underlay_interface": "eth0",
    "local_vtep": "10.10.20.10",
    "remote_vtep": "10.10.10.1",
    "udp_port": 4789,
    "mtu": 1450
  },
  "bridges": [
    {
      "name": "br40",
      "mtu": 1450,
      "multicast_snooping": false,
      "stp": false
    }
  ],
  "tunnels": [
    {
      "name": "vx40",
      "vni": 40,
      "bridge": "br40"
    }
  ],
  "docker_networks": [
    {
      "name": "vxlan-iot",
      "parent": "br40",
      "subnet": "192.168.40.0/24",
      "gateway": "192.168.40.1",
      "ip_range": "192.168.40.192/27"
    }
  ]
}
```

See the selected deployment guide for the complete configuration reference and operational commands.

## Documentation

- [Docker-only bootstrap](container-bootstrap.md)
- [Boot-safe systemd + Docker bootstrap](boot-safe.md)
- [MikroTik RouterOS v7 VXLAN configuration](mikrotik.md)

## Main files

```text
.
├── README.md
├── container-bootstrap.md
├── boot-safe.md
├── mikrotik.md
├── config.json
├── compose.yml
├── Dockerfile
├── entrypoint.sh
├── host-bootstrap.sh
└── install.sh
```

## Quick status checks

Docker bootstrap:

```bash
docker inspect --format='{{.State.Health.Status}}' vxlan-bootstrap
```

Boot-safe installation:

```bash
sudo ./install.sh status
```

Linux VXLAN interfaces:

```bash
ip -d link show type vxlan
```

Linux bridges:

```bash
bridge link
```

## License

No license has been selected yet. Add an explicit license before treating the repository as reusable open-source software.
