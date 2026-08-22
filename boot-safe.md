# Boot-safe VXLAN startup on UGREEN DXP / UGOS

This mode guarantees that the Linux bridge and VXLAN parent interfaces exist before `docker.service` starts.

It is intended for DXP systems where Docker containers use the macvlan networks created by this project and have normal Docker restart policies such as `restart: unless-stopped`.

## Why this is needed

Docker network objects are persistent in the Docker daemon state, but Linux interfaces created with `ip link` are runtime objects and disappear after a reboot.

Without boot-safe mode the sequence can be:

```text
Docker daemon starts
        |
        +--> workload container restart begins
        |        |
        |        X parent bridge does not exist yet
        |
        +--> vxlan-bootstrap starts later
                 |
                 +--> creates bridge/VXLAN
```

Boot-safe mode changes the order to:

```text
network-online.target
        |
        v
ugreen-vxlan-host-bootstrap.service
        |
        +--> Linux bridges
        +--> VXLAN interfaces
        |
        v
docker.service ExecStartPre
        |
        +--> idempotent bridge/VXLAN re-check
        |
        v
dockerd
        |
        +--> Docker restores persistent macvlan networks
        +--> Docker restarts existing workload containers
        |
        v
vxlan-bootstrap container
        |
        +--> validates/reconciles bridge + VXLAN
        +--> creates/validates Docker macvlan networks
        +--> healthcheck
```

The DXP host still receives no IP address from the stretched networks.

## Compatibility with the existing configuration

No change to `config.json` is required.

The same sections remain authoritative:

```json
{
  "global": {
    "underlay_interface": "eth0",
    "local_vtep": "10.10.20.10",
    "remote_vtep": "10.10.10.1",
    "udp_port": 4789,
    "mtu": 1450
  },
  "bridges": [],
  "tunnels": [],
  "docker_networks": []
}
```

During installation, `install.sh` uses the `jq` already bundled in the bootstrap image to render only the pre-Docker information into:

```text
.host-bootstrap/host-config.tsv
```

The generated file contains only:

- global underlay/VTEP settings;
- Linux bridge definitions;
- VXLAN definitions.

Docker network definitions remain managed by the normal bootstrap container.

This avoids introducing a `jq` or Python dependency into the early host boot path.

## Installation

Keep the repository on persistent DXP storage, for example:

```bash
cd /volume1/docker/ugreen-dxp-vxlan-bootstrap
```

Make sure the existing `config.json` contains the desired configuration, then run:

```bash
sudo ./install.sh install
```

The installer is idempotent and performs the following steps:

1. checks that `docker.service`, Docker Compose v2 and the Docker daemon are available;
2. builds the existing bootstrap image;
3. validates `config.json`;
4. renders `.host-bootstrap/host-config.tsv`;
5. installs `/etc/systemd/system/ugreen-vxlan-host-bootstrap.service`;
6. installs `/etc/systemd/system/docker.service.d/10-ugreen-vxlan-host-bootstrap.conf`;
7. enables the host bootstrap service;
8. applies bridge/VXLAN state immediately without restarting Docker;
9. starts/reconciles the normal `vxlan-bootstrap` container;
10. waits until the container becomes healthy.

The installer does **not** restart Docker, so existing application containers are not intentionally interrupted during installation.

## What is installed in systemd

The generated host service is a `oneshot` unit ordered after `network-online.target` and before `docker.service`.

It also uses `RequiresMountsFor=` so the persistent project directory is mounted before the pre-Docker script is executed. Missing generated configuration is treated as a hard failure with `AssertPathExists=` rather than as an optional condition.

The Docker drop-in contains both a hard dependency and a per-start preflight:

```ini
[Unit]
Requires=ugreen-vxlan-host-bootstrap.service
After=ugreen-vxlan-host-bootstrap.service

[Service]
ExecStartPre=/bin/bash /volumeX/.../host-bootstrap.sh apply /volumeX/.../.host-bootstrap/host-config.tsv
```

This is deliberate. `Requires=` guarantees the boot dependency, while `ExecStartPre=` re-applies and validates the bridge/VXLAN state on **every** start of `docker.service`, including a Docker restart later in the same system boot.

If that preflight fails, `dockerd` is not started.

## Status

Run:

```bash
sudo ./install.sh status
```

It displays:

- systemd bootstrap state;
- Docker unit dependencies;
- generated host configuration;
- bridge/VXLAN state;
- bootstrap container state and health.

Useful manual checks:

```bash
systemctl status ugreen-vxlan-host-bootstrap.service
systemctl show docker.service -p Requires -p After
systemctl cat docker.service
journalctl -u ugreen-vxlan-host-bootstrap.service -b
ip -d link show type vxlan
bridge link
docker inspect --format='{{.State.Health.Status}}' vxlan-bootstrap
```

After a reboot, the expected relationship is visible with:

```bash
systemd-analyze critical-chain docker.service
```

and `docker.service` should show the VXLAN host bootstrap earlier in its dependency chain.

## Changing config.json

For ordinary additions or mutable settings, edit `config.json` and synchronize the pre-Docker snapshot:

```bash
sudo ./install.sh sync
```

`sync` performs config validation, regenerates the host snapshot, reapplies the host networking and reconciles the Docker bootstrap container.

Always run `sync` after editing `config.json`; the generated `.host-bootstrap/host-config.tsv` is intentionally not edited by hand.

### Immutable VXLAN changes

Changing an existing VNI, local VTEP, remote VTEP, UDP port or underlay is intentionally not replaced silently.

For those changes:

1. stop workloads using the affected Docker networks;
2. keep the **old** `config.json` in place;
3. stop the resident bootstrap container;
4. run the existing cleanup action using the old configuration;
5. edit `config.json`;
6. run `sudo ./install.sh sync`.

Example:

```bash
docker compose stop vxlan-bootstrap
docker compose run --rm --no-deps vxlan-bootstrap cleanup
vi config.json
sudo ./install.sh sync
```

Cleanup remains conservative and will refuse to remove a bridge that contains foreign interfaces, including VM TAP interfaces.

## Docker restart policies

Workload containers can keep their normal policies, for example:

```yaml
restart: unless-stopped
```

The design does not depend on `depends_on` across separate Compose projects.

On a normal reboot, existing Docker macvlan network definitions are restored from Docker's persistent state. The critical host-side parent bridges and VXLAN devices are recreated before `docker.service` starts.

The normal `vxlan-bootstrap` container remains useful after Docker starts because it validates the complete desired state and creates a missing Docker network during installation or manual reconciliation.

## First installation

Before the first reboot, always let the installer finish successfully and confirm:

```bash
sudo ./install.sh status
```

The bootstrap container must be healthy and all configured Docker networks must already exist. This ensures Docker has persistent network definitions available at the next boot.

## Uninstall boot-safe integration

To remove only the systemd boot ordering:

```bash
sudo ./install.sh uninstall
```

This intentionally does **not** remove live bridges, VXLAN interfaces or Docker networks and does not stop workload containers.

If the runtime VXLAN configuration should also be removed, first stop dependent containers and then use the existing cleanup procedure:

```bash
docker compose stop vxlan-bootstrap
docker compose run --rm --no-deps vxlan-bootstrap cleanup
```

## UGOS upgrades

The project directory and generated host configuration should live on the persistent storage pool.

The boot integration itself uses files below `/etc/systemd/system`. After a major UGOS or Docker application upgrade, verify it with:

```bash
sudo ./install.sh status
```

If the systemd unit or Docker drop-in was removed by an upgrade, reinstall it idempotently:

```bash
sudo ./install.sh install
```

No change to `config.json` is required.

## Failure behavior

Boot-safe mode intentionally uses a hard dependency and a Docker `ExecStartPre` check.

If bridge/VXLAN creation or validation fails, Docker is prevented from starting. This is deliberate: starting Docker workloads while their L2 parent interfaces are missing would recreate the original race condition and could leave applications in a partially connected state.

Troubleshoot with:

```bash
systemctl status ugreen-vxlan-host-bootstrap.service
journalctl -u ugreen-vxlan-host-bootstrap.service -b
systemctl status docker.service
```

After correcting the configuration or underlay problem:

```bash
systemctl restart ugreen-vxlan-host-bootstrap.service
systemctl start docker.service
```
