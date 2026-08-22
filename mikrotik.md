# MikroTik RouterOS VXLAN configuration

This document shows an example MikroTik RouterOS v7 configuration for use as the **central VXLAN VTEP** for the UGREEN DXP VXLAN Bootstrap project.

The example matches the sample `config.json` from this repository and assumes:

- the UGREEN DXP terminates several VXLAN VNIs;
- all VXLANs use the same central MikroTik router as the remote VTEP;
- the DXP host does **not** receive IP addresses from the extended LANs;
- Docker containers receive addresses directly from those LANs through macvlan;
- the MikroTik is the Layer-3 gateway for the extended networks;
- the MikroTik may also bridge each extended VXLAN into an existing local VLAN.

## Example topology

```text
                         MikroTik RouterOS
                        VTEP 10.10.10.1
                               |
             +-----------------+-----------------+
             |                 |                 |
           VNI 30            VNI 40            VNI 50
             |                 |                 |
          VLAN 30           VLAN 40           VLAN 50
      192.168.30.0/24   192.168.40.0/24   192.168.50.0/24
             |
             |            routed underlay
             |
                         UGREEN DXP
                       VTEP 10.10.20.10
                               |
              +----------------+----------------+
              |                |                |
             vx30             vx40             vx50
              |                |                |
             br30             br40             br50
              |                |                |
          vxlan-ha         vxlan-iot       vxlan-audio
              |
       Home Assistant
       192.168.30.200
       gateway 192.168.30.1
```

## Addressing used in this example

| Purpose | Value |
|---|---|
| MikroTik VTEP | `10.10.10.1` |
| DXP VTEP | `10.10.20.10` |
| VXLAN UDP port | `4789` |
| VNI 30 / VLAN 30 | `192.168.30.0/24` |
| VNI 40 / VLAN 40 | `192.168.40.0/24` |
| VNI 50 / VLAN 50 | `192.168.50.0/24` |
| MikroTik gateway for VLAN 30 | `192.168.30.1` |
| MikroTik gateway for VLAN 40 | `192.168.40.1` |
| MikroTik gateway for VLAN 50 | `192.168.50.1` |
| Example local VLAN trunk | `sfp-sfpplus1` |
| Example existing LAN bridge | `br-lan` |

The corresponding DXP-side global configuration is similar to:

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

Replace all addresses and interface names with values appropriate for your environment.

---

## 1. Verify underlay reachability first

VXLAN will not work until the two VTEPs can reach each other through the normal routed network.

The MikroTik must have a route toward the DXP VTEP address:

```routeros
/ip route
add dst-address=10.10.20.10/32 gateway=10.20.0.2 comment="UGREEN DXP VXLAN VTEP"
```

Replace `10.20.0.2` with the real next hop.

Test before proceeding:

```routeros
/ping 10.10.20.10
```

If a dedicated loopback address is used for the MikroTik VTEP, also verify the reverse route on the DXP/underlay network.

---

## 2. Create a stable MikroTik VTEP address

Using a loopback-style interface is recommended when the underlay routing design supports it. This keeps the VTEP address independent from a specific physical interface.

```routeros
/interface bridge
add name=lo protocol-mode=none comment="Loopback"

/ip address
add address=10.10.10.1/32 interface=lo comment="VXLAN VTEP"
```

The DXP must have a route to `10.10.10.1`.

Verify from the MikroTik using the VTEP as the source address:

```routeros
/ping 10.10.20.10 src-address=10.10.10.1
```

Do not continue until bidirectional underlay reachability is working.

---

## 3. Create VXLAN interfaces

Create one RouterOS VXLAN interface for each VNI configured on the DXP:

```routeros
/interface vxlan
add name=vxlan30 vni=30 local-address=10.10.10.1 port=4789 mtu=1450
add name=vxlan40 vni=40 local-address=10.10.10.1 port=4789 mtu=1450
add name=vxlan50 vni=50 local-address=10.10.10.1 port=4789 mtu=1450
```

The `local-address` should match the address used as `remote_vtep` in the DXP `config.json`.

RouterOS uses UDP port `4789` by default for VXLAN. Keep the port identical on both endpoints.

### MTU

VXLAN over IPv4 adds approximately 50 bytes of encapsulation overhead.

For a normal 1500-byte underlay, this example uses:

```text
underlay MTU: 1500
overlay MTU:  1450
```

If the entire underlay supports a larger MTU, it is preferable to increase the underlay MTU and retain an overlay MTU of 1500.

For example:

```text
underlay MTU: >=1550
overlay MTU:  1500
```

or use jumbo frames end-to-end.

---

## 4. Configure the DXP as a static remote VTEP

RouterOS uses statically configured remote VTEPs.

Add the DXP VTEP to each VXLAN interface:

```routeros
/interface vxlan vteps
add interface=vxlan30 remote-ip=10.10.20.10 comment="UGREEN DXP VNI 30"
add interface=vxlan40 remote-ip=10.10.20.10 comment="UGREEN DXP VNI 40"
add interface=vxlan50 remote-ip=10.10.20.10 comment="UGREEN DXP VNI 50"
```

All VNIs may point to the same remote VTEP address.

Check the configuration:

```routeros
/interface vxlan print detail
/interface vxlan vteps print detail
```

---

## 5. Map each VXLAN to a local VLAN

The generic configuration below works with a normal RouterOS VLAN-aware bridge and does not depend on VXLAN hardware offload.

It maps:

```text
VNI 30 <-> VLAN 30
VNI 40 <-> VLAN 40
VNI 50 <-> VLAN 50
```

The VXLAN-facing side is treated as an **untagged access port** in the appropriate VLAN.

This means the DXP-side VXLAN carries ordinary Ethernet frames; RouterOS performs the local bridge VLAN classification.

### Add VXLAN interfaces to the bridge

Assuming the existing VLAN-aware bridge is named `br-lan`:

```routeros
/interface bridge port
add bridge=br-lan interface=vxlan30 pvid=30 ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=br-lan interface=vxlan40 pvid=40 ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=br-lan interface=vxlan50 pvid=50 ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged
```

If a physical interface such as `sfp-sfpplus1` carries VLANs 30/40/50 toward a local switch, configure it as a tagged trunk:

```routeros
/interface bridge port
add bridge=br-lan interface=sfp-sfpplus1 ingress-filtering=yes frame-types=admit-only-vlan-tagged
```

Do not add this line if the interface is already a member of the bridge.

### Bridge VLAN table

```routeros
/interface bridge vlan
add bridge=br-lan vlan-ids=30 tagged=br-lan,sfp-sfpplus1 untagged=vxlan30
add bridge=br-lan vlan-ids=40 tagged=br-lan,sfp-sfpplus1 untagged=vxlan40
add bridge=br-lan vlan-ids=50 tagged=br-lan,sfp-sfpplus1 untagged=vxlan50
```

The `br-lan` bridge itself is listed as tagged because the MikroTik CPU will terminate Layer-3 VLAN interfaces and act as the default gateway.

If there is no physical trunk and the VXLAN segment exists only between MikroTik and the DXP, omit `sfp-sfpplus1` from the VLAN table.

For example:

```routeros
/interface bridge vlan
add bridge=br-lan vlan-ids=30 tagged=br-lan untagged=vxlan30
```

---

## 6. Configure the MikroTik as the Layer-3 gateway

Create VLAN interfaces on the bridge:

```routeros
/interface vlan
add name=vlan30 interface=br-lan vlan-id=30 comment="HA network"
add name=vlan40 interface=br-lan vlan-id=40 comment="IoT network"
add name=vlan50 interface=br-lan vlan-id=50 comment="Audio network"
```

Assign gateway addresses:

```routeros
/ip address
add address=192.168.30.1/24 interface=vlan30 comment="HA gateway"
add address=192.168.40.1/24 interface=vlan40 comment="IoT gateway"
add address=192.168.50.1/24 interface=vlan50 comment="Audio gateway"
```

A Docker container attached to the DXP `vxlan-ha` network can then use:

```text
IP address: 192.168.30.200/24
Gateway:    192.168.30.1
```

The packet path is:

```text
Home Assistant container
192.168.30.200
       |
       v
Docker macvlan
       |
       v
DXP br30
       |
       v
DXP vx30
       |
       v
VXLAN / UDP 4789
       |
       v
MikroTik vxlan30
       |
       v
br-lan / VLAN 30
       |
       v
192.168.30.1
```

The DXP itself still has no `192.168.30.x` address.

---

## 7. Enable VLAN filtering

If `br-lan` is already a production VLAN-aware bridge, VLAN filtering will normally already be enabled.

Check:

```routeros
/interface bridge print detail where name=br-lan
```

If creating the bridge from scratch, configure all bridge ports and VLAN table entries **before** enabling VLAN filtering to avoid locking yourself out.

Then enable it:

```routeros
/interface bridge
set br-lan vlan-filtering=yes
```

Be especially careful when changing VLAN filtering remotely.

---

## 8. Allow VXLAN through the MikroTik input firewall

VXLAN packets are addressed to the router itself, so a normal RouterOS input firewall may block them.

Add a narrowly scoped rule before the generic input drop rule:

```routeros
/ip firewall filter
add chain=input action=accept protocol=udp \
    src-address=10.10.20.10 \
    dst-address=10.10.10.1 \
    dst-port=4789 \
    comment="Allow VXLAN from UGREEN DXP"
```

Avoid allowing UDP/4789 from arbitrary sources.

If the VXLAN underlay crosses another firewall, UDP/4789 must also be permitted there.

---

## 9. Complete example

The following example assumes:

- `br-lan` already exists;
- `sfp-sfpplus1` is the local VLAN trunk;
- routing to `10.10.20.10` is already working;
- VLAN filtering is enabled only after the VLAN configuration is complete.

```routeros
# ============================================================
# Stable VTEP / loopback
# ============================================================

/interface bridge
add name=lo protocol-mode=none comment="Loopback"

/ip address
add address=10.10.10.1/32 interface=lo comment="VXLAN VTEP"


# ============================================================
# VXLAN interfaces
# ============================================================

/interface vxlan
add name=vxlan30 vni=30 local-address=10.10.10.1 port=4789 mtu=1450
add name=vxlan40 vni=40 local-address=10.10.10.1 port=4789 mtu=1450
add name=vxlan50 vni=50 local-address=10.10.10.1 port=4789 mtu=1450


# ============================================================
# Static remote DXP VTEP
# ============================================================

/interface vxlan vteps
add interface=vxlan30 remote-ip=10.10.20.10 comment="UGREEN DXP VNI 30"
add interface=vxlan40 remote-ip=10.10.20.10 comment="UGREEN DXP VNI 40"
add interface=vxlan50 remote-ip=10.10.20.10 comment="UGREEN DXP VNI 50"


# ============================================================
# VXLAN interfaces as access ports in matching VLANs
# ============================================================

/interface bridge port
add bridge=br-lan interface=vxlan30 pvid=30 ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=br-lan interface=vxlan40 pvid=40 ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=br-lan interface=vxlan50 pvid=50 ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged


# ============================================================
# Local VLAN trunk - omit if already configured
# ============================================================

/interface bridge port
add bridge=br-lan interface=sfp-sfpplus1 ingress-filtering=yes frame-types=admit-only-vlan-tagged


# ============================================================
# VLAN to VXLAN mapping
# ============================================================

/interface bridge vlan
add bridge=br-lan vlan-ids=30 tagged=br-lan,sfp-sfpplus1 untagged=vxlan30
add bridge=br-lan vlan-ids=40 tagged=br-lan,sfp-sfpplus1 untagged=vxlan40
add bridge=br-lan vlan-ids=50 tagged=br-lan,sfp-sfpplus1 untagged=vxlan50


# ============================================================
# L3 interfaces / default gateways
# ============================================================

/interface vlan
add name=vlan30 interface=br-lan vlan-id=30 comment="HA network"
add name=vlan40 interface=br-lan vlan-id=40 comment="IoT network"
add name=vlan50 interface=br-lan vlan-id=50 comment="Audio network"

/ip address
add address=192.168.30.1/24 interface=vlan30 comment="HA gateway"
add address=192.168.40.1/24 interface=vlan40 comment="IoT gateway"
add address=192.168.50.1/24 interface=vlan50 comment="Audio gateway"


# ============================================================
# VXLAN underlay firewall
# Place before a generic INPUT drop rule
# ============================================================

/ip firewall filter
add chain=input action=accept protocol=udp \
    src-address=10.10.20.10 \
    dst-address=10.10.10.1 \
    dst-port=4789 \
    comment="VXLAN from UGREEN DXP"
```

---

## 10. Verification

### Underlay

```routeros
/ping 10.10.20.10 src-address=10.10.10.1
```

### VXLAN interfaces

```routeros
/interface vxlan print detail
```

### Static VTEPs

```routeros
/interface vxlan vteps print detail
```

### Learned VXLAN MAC addresses

RouterOS 7.9 and newer can show MAC addresses learned through remote VTEPs:

```routeros
/interface vxlan fdb print detail
```

For a Home Assistant container on VNI 30, its MAC should eventually appear with:

```text
interface=vxlan30
remote-ip=10.10.20.10
```

### Bridge MAC table

```routeros
/interface bridge host print where on-interface=vxlan30
```

### Gateway reachability

After starting the container:

```routeros
/ping 192.168.30.200 src-address=192.168.30.1
```

### Traffic capture

To verify encapsulated VXLAN traffic on the MikroTik:

```routeros
/tool sniffer quick ip-protocol=udp port=4789
```

You should see traffic between:

```text
10.10.10.1 <-> 10.10.20.10
```

---

## 11. Home Assistant multicast and discovery

One reason to extend Layer 2 to Home Assistant is to preserve protocols that do not naturally cross routed boundaries, including:

- ARP/broadcast;
- mDNS (`224.0.0.251:5353`);
- SSDP (`239.255.255.250:1900`);
- some HomeKit, Cast, discovery, and IoT protocols.

The expected forwarding path is:

```text
remote VLAN 30
      |
      v
MikroTik br-lan
      |
      v
vxlan30
      |
      v
DXP vx30
      |
      v
DXP br30
      |
      v
Docker macvlan
      |
      v
Home Assistant
```

For small Home Assistant/IoT broadcast domains, the DXP sample configuration disables multicast snooping on the managed Linux bridges so multicast is predictably flooded over the VXLAN.

Be aware that behavior on the MikroTik side may differ depending on model, bridge hardware offload, RouterOS release, and multicast-snooping settings. Test mDNS/SSDP explicitly after deployment.

---

## 12. RouterOS 7.18+ hardware-offloaded VXLAN

RouterOS 7.18 introduced initial VXLAN hardware-offload support on selected switch-chip platforms.

On supported devices RouterOS can provide static one-to-one VLAN-to-VXLAN mapping directly in a VLAN-filtering bridge, and newer syntax may allow properties such as `bridge` and `bridge-pvid` directly on the VXLAN interface.

Do **not** assume that the hardware-offloaded path is available on every MikroTik model.

The generic configuration in this document deliberately uses:

```text
VXLAN interface
      |
/interface bridge port with PVID
      |
bridge VLAN table
```

because it is easier to understand and applies to a broader range of RouterOS devices.

If the MikroTik is a CRS model and performance matters, check the RouterOS documentation for the exact switch chip and RouterOS version before converting this example to hardware-offloaded VXLAN.

Important limitations documented for current hardware-offloaded VXLAN implementations may include restrictions involving:

- VTEPs over ECMP;
- VTEPs over bond/bridge/VLAN underlay interfaces;
- VRFs;
- IPv6 VTEPs;
- IGMP snooping on bridged VXLAN;
- MLAG;
- routing between different VXLAN VNIs.

These restrictions apply to the hardware-offloaded implementation and should be verified for the specific device and RouterOS release.

---

## 13. Troubleshooting checklist

### No traffic at all

Check in this order:

1. DXP can route to `10.10.10.1`.
2. MikroTik can route to `10.10.20.10`.
3. UDP/4789 is allowed in both directions.
4. VNI values are identical on both sides.
5. VXLAN UDP ports are identical.
6. MikroTik static VTEP points to `10.10.20.10`.
7. DXP `remote_vtep` points to `10.10.10.1`.

### ARP works but larger packets fail

Suspect MTU first.

Check the underlay path and either:

- use overlay MTU 1450 over an IPv4 underlay MTU of 1500; or
- raise the underlay MTU enough to carry a full 1500-byte inner Ethernet payload.

### Container can reach the gateway but not local VLAN hosts

Check:

```routeros
/interface bridge vlan print detail
/interface bridge port print detail
/interface bridge host print
```

Verify that the VXLAN interface is untagged in the expected VLAN and has the correct PVID.

### Unicast works but mDNS/SSDP does not

Check multicast/broadcast handling on both bridges.

On MikroTik inspect:

```routeros
/interface bridge print detail
/interface bridge mdb print
```

On the DXP use the bootstrap `status` command and packet capture on the Linux bridge/VXLAN interface.

### VXLAN FDB remains empty

Generate traffic from a DXP-side container and check:

```routeros
/interface vxlan fdb print detail
/interface bridge host print
```

Also capture UDP/4789 to confirm that encapsulated frames are reaching the router.

---

## References

- MikroTik RouterOS VXLAN documentation: https://help.mikrotik.com/docs/spaces/ROS/pages/100007937/VXLAN
- MikroTik RouterOS Bridging and Switching documentation: https://help.mikrotik.com/docs/spaces/ROS/pages/328068/Bridging+and+Switching
- RFC 7348 — Virtual eXtensible Local Area Network (VXLAN): https://datatracker.ietf.org/doc/html/rfc7348

The MikroTik documentation site is transitioning to the newer RouterOS manual. Always verify model-specific hardware-offload capabilities and syntax against the documentation matching the RouterOS version installed on the target router.
