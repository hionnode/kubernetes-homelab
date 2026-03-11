# OPNsense VLAN Setup — Deep Dive

**Environment:** OPNsense 25.7 · Proxmox VE 8.x · TP-Link TL-SG2008 (Omada)
**Scope:** VLAN 10 setup for a single homelab subnet (10.0.0.0/24), recovery from LAN lockout, and the correct procedure for both single-VLAN and trunk configurations.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Key Terms — Glossary](#2-key-terms--glossary)
3. [Visual Concepts](#3-visual-concepts)
4. [Why the Lockout Happens](#4-why-the-lockout-happens)
5. [Recovery: Restore OPNsense Access via Proxmox Console](#5-recovery-restore-opnsense-access-via-proxmox-console)
6. [Option A: Single VLAN, No Trunk (Recommended)](#6-option-a-single-vlan-no-trunk-recommended)
7. [Option B: VLAN Trunk (Multi-VLAN Ready)](#7-option-b-vlan-trunk-multi-vlan-ready)
8. [OPNsense 25.7 Specific Notes](#8-opnsense-257-specific-notes)
9. [Verification Checklist](#9-verification-checklist)
10. [Troubleshooting](#10-troubleshooting)
11. [Networking Prerequisites & Tools](#11-networking-prerequisites--tools)
12. [References](#12-references)

---

## 1. Overview

This document covers VLAN configuration for a setup where:

- OPNsense runs as a VM (VM 101) on Proxmox, with two virtual NICs:
  - `vtnet0` — WAN, connected to Proxmox bridge `vmbr0` (upstream router 192.168.1.x)
  - `vtnet1` — LAN, connected to Proxmox bridge `vmbr1` (homelab 10.0.0.x)
- `vmbr1` bridges to a physical NIC (`enx1c860b363f63`) that connects to a TP-Link TL-SG2008 switch
- The target VLAN is VLAN 10 (`homelab-lan`, 10.0.0.0/24)
- OPNsense is the DHCP server and default gateway (10.0.0.1)

There are two valid approaches to VLAN setup:

| | Option A (No Trunk) | Option B (Trunk) |
|---|---|---|
| LAN stays `vtnet1` | Yes — untagged | No — moves to `vtnet1_vlan10` |
| Proxmox changes needed | None | Enable VLAN-aware on vmbr1 |
| Switch uplink | Untagged VLAN 10 | Tagged VLAN 10 |
| Future-proof for more VLANs | No | Yes |
| Risk of lockout | None | High if done out of order |

**If you are currently locked out, skip to [Section 5](#5-recovery-restore-opnsense-access-via-proxmox-console).**

---

## 2. Key Terms — Glossary

### VLAN (Virtual LAN)

A VLAN is a logical partition of a physical network. Devices on the same VLAN communicate as if they share a dedicated switch, even though the underlying hardware is shared with other VLANs. VLANs enforce traffic isolation at Layer 2 — a device on VLAN 10 cannot receive broadcast frames from VLAN 20 even if both are on the same physical switch.

### 802.1Q

IEEE 802.1Q is the standard that defines how VLAN membership is carried inside Ethernet frames. It specifies a 4-byte "tag" inserted into the frame header that identifies which VLAN the frame belongs to. Any switch, bridge, or NIC that participates in VLAN-tagged traffic must understand 802.1Q.

### VLAN ID (VID)

The VLAN ID is a 12-bit numeric field inside the 802.1Q tag. Valid values are 1–4094 (0 and 4095 are reserved). In this homelab, VID=10 identifies the `homelab-lan` network. The VID is what a switch reads to decide which VLAN domain a tagged frame belongs to.

### Tagged Frame

A tagged frame is an Ethernet frame that has had a 4-byte 802.1Q header inserted after the source MAC address. The tag contains the VLAN ID. Tagged frames are used on trunk ports and uplinks — places where multiple VLANs must coexist on a single wire. A device that does not understand 802.1Q will typically reject or mishandle tagged frames.

### Untagged Frame

An untagged frame is a standard Ethernet frame with no 802.1Q header. Devices like laptops, printers, and IoT gadgets normally send and receive only untagged frames. Switch access ports convert between the device's untagged frames and the switch's internal VLAN domain using the PVID.

### PVID (Port VLAN ID)

The PVID is the VLAN ID a switch port assigns to untagged frames arriving on that port (ingress). When a device sends an untagged frame into a port configured with PVID=10, the switch internally tags the frame with VID=10 and forwards it within VLAN 10. On egress, if the destination port is configured to send VLAN 10 as untagged, the switch strips the tag before sending the frame to the device.

### Trunk Port

A trunk port is a switch port that carries multiple VLANs simultaneously using 802.1Q tagged frames. Every frame leaving a trunk port carries an explicit VLAN ID tag so the receiving end knows which VLAN it belongs to. Trunk ports are used on uplinks between switches, and between a switch and a router (or in this homelab, between the SG2008 and the Proxmox physical NIC).

### Access Port

An access port is a switch port that carries a single VLAN using untagged frames. The port is a member of exactly one VLAN, and its PVID is set to that VLAN. End devices (PCs, servers) connect to access ports and never see VLAN tags — the switch handles all tagging internally. Access ports are the normal connection point for devices that don't understand 802.1Q.

### Native VLAN

On a trunk port, the native VLAN is the one VLAN for which frames are sent and received *without* a tag. All other VLANs on the trunk use tagged frames. The native VLAN is a compatibility mechanism — devices that send untagged frames into a trunk port land in the native VLAN. Mismatched native VLANs on the two ends of a trunk cause traffic to end up in the wrong VLAN. In this homelab, if the switch uplink (port 8) has a native VLAN, frames from Proxmox without a tag will be assigned to it.

### Linux Bridge (vmbr)

A Linux bridge (`vmbr0`, `vmbr1`) is a kernel-mode Layer 2 switch built into the Linux host that Proxmox runs on. It connects VM virtual NICs (tap devices) to physical NICs, allowing VMs to communicate with the physical network. By default, a Linux bridge behaves like a simple switch — it forwards Ethernet frames but has no VLAN awareness.

### VLAN-Aware Bridge

A VLAN-aware bridge is a Linux bridge configured to understand and preserve 802.1Q tags. When `bridge-vlan-aware yes` is set, the bridge passes tagged frames through to the physical NIC with the tag intact. Without this setting, the bridge strips VLAN tags from frames before forwarding them, which breaks VLAN-tagged traffic from OPNsense subinterfaces.

### TAP Device (tapXXXiY)

A tap device (e.g., `tap101i1`) is the virtual cable connecting a VM's NIC to the host bridge. When OPNsense (VM 101) emits a frame from its `vtnet1` NIC, that frame appears on `tap101i1` in the Proxmox host. The bridge then forwards it toward the physical NIC. The tap device itself is transparent — it doesn't add or remove VLAN tags.

### Subinterface (vtnet1_vlan10)

A VLAN subinterface is a logical NIC layered on top of a parent physical (or virtual) NIC. It filters traffic by VLAN ID — it only sends and receives frames tagged with its configured VID. In OPNsense, `vtnet1_vlan10` is a subinterface of `vtnet1` that exclusively handles VID=10 frames. Creating a subinterface does not affect the parent interface's behavior.

### Parent Interface (vtnet1)

The parent interface is the physical or virtual NIC that a VLAN subinterface is attached to. In OPNsense, `vtnet1` is the parent of `vtnet1_vlan10`. The parent interface must receive (or be capable of receiving) tagged frames from the bridge for the subinterface to work. If the bridge strips tags before they reach `vtnet1`, the subinterface sees no traffic.

### Anti-Lockout Rule

The anti-lockout rule is an automatically generated OPNsense firewall rule that allows WebGUI access (TCP 443/80) from any host on the LAN interface. It exists to prevent accidental self-lockout during firewall configuration. The rule is attached to whichever interface OPNsense considers the primary LAN — if that interface goes offline or receives no traffic (due to a VLAN misconfiguration), the anti-lockout rule has no effect and WebGUI becomes unreachable from the LAN side.

---

## 3. Visual Concepts

### 3.1 Ethernet Frame Anatomy — Where the 802.1Q Tag Lives

An untagged Ethernet frame has six fields. When 802.1Q tagging is applied, a 4-byte tag is inserted between the source MAC address and the EtherType field, expanding the minimum frame size by 4 bytes.

```
Standard Ethernet frame (untagged):
┌──────────┬──────────┬───────────┬─────────────┬──────────┐
│ Dst MAC  │ Src MAC  │ EtherType │   Payload   │   FCS    │
│  6 bytes │  6 bytes │  2 bytes  │  46–1500 B  │  4 bytes │
└──────────┴──────────┴───────────┴─────────────┴──────────┘

802.1Q tagged frame (tag inserted after Src MAC):
┌──────────┬──────────┬──────────────────────┬───────────┬─────────────┬──────────┐
│ Dst MAC  │ Src MAC  │    802.1Q Tag (4B)   │ EtherType │   Payload   │   FCS    │
│  6 bytes │  6 bytes │  TPID(2B) + TCI(2B) │  2 bytes  │  46–1500 B  │  4 bytes │
└──────────┴──────────┴──────────────────────┴───────────┴─────────────┴──────────┘
                                │
               ┌────────────────┴─────────────────────┐
               │  TPID = 0x8100  (identifies 802.1Q)  │
               │  TCI = Tag Control Information        │
               │    PCP  (3 bits) — 802.1p priority    │
               │    DEI  (1 bit)  — drop eligibility   │
               │    VID  (12 bits)— VLAN ID (1–4094)   │
               │               e.g. VID=10 for VLAN 10 │
               └───────────────────────────────────────┘
```

The TPID value `0x8100` is what lets a switch distinguish a tagged frame from an untagged one — an untagged frame would have its actual EtherType (e.g., `0x0800` for IPv4) in that position instead.

---

### 3.2 Tagged vs Untagged — Where Tags Appear and Disappear

This shows the same data frame travelling through two different port configurations. Notice that the tag only ever appears on the wire between trunk-capable devices.

```
ACCESS PORT path (single VLAN, no tags visible to end device):

  End device          Switch port 3           Switch internal      Switch port 5        End device
  (VLAN 10)           ACCESS, PVID=10         fabric               ACCESS, PVID=10      (VLAN 10)
  ──────────          ─────────────────       ────────────         ─────────────────    ──────────
  [frame]             ingress:                                     egress:
    │                  adds tag VID=10                              strips tag
    │──── untagged ──▶ [frame|VID=10] ──────────────────────────▶ [frame] ──────────▶  [frame]
                       "this is VLAN 10"                           "back to untagged"


TRUNK PORT path (multiple VLANs, tags visible on wire):

  OPNsense            Proxmox vmbr1           Physical wire        Switch port 8
  vtnet1_vlan10       VLAN-aware bridge       to switch            TRUNK, Tagged VID=10
  ─────────────       ─────────────────       ─────────────        ─────────────────────
  [frame|VID=10]
    │
    │── tagged ──────▶ passes tag through ──▶ [frame|VID=10] ──▶  accepted (tag intact)
                        (no stripping)                              routes to VLAN 10
```

The key insight: tags on the wire between OPNsense and the switch only work if the Proxmox bridge is VLAN-aware. An unaware bridge silently strips the tag, and the switch never sees the VLAN ID.

---

### 3.3 PVID in Action — Ingress Tagging and Egress Stripping

This shows the lifecycle of a frame as it crosses a switch boundary, from an untagged device on one port to another.

```
Ingress (device → switch):

   Device                 Switch port 3               Switch fabric
   ──────                 ─────────────               ─────────────
  [frame]                 PVID = 10
    │                         │
    │──── untagged frame ────▶│ switch assigns VID=10 ──▶ [frame | VID=10]
                               │                            travels VLAN 10
                               "no tag? use my PVID"         domain internally


Egress (switch → device, same VLAN, untagged port):

   Switch fabric          Switch port 5               Device
   ─────────────          ─────────────               ──────
  [frame | VID=10]        untagged member of VLAN 10
    │
    │──────────────────▶ strip VID=10 tag ──────────▶ [frame]
                          "this port sends
                           VLAN 10 as untagged"


Egress (switch → uplink, trunk port — tag preserved):

   Switch fabric          Switch port 8               Proxmox NIC
   ─────────────          ─────────────               ───────────
  [frame | VID=10]        Tagged member of VLAN 10
    │
    │──────────────────▶ keep tag intact ───────────▶ [frame | VID=10]
                          "trunk port — send
                           the tag so the other
                           end knows the VLAN"
```

---

### 3.4 Trunk vs Access Port — Why Trunks Exist

A single physical wire between the switch and Proxmox must carry traffic for multiple VLANs. Without a trunk, you would need one physical cable per VLAN. The trunk port uses tags to multiplex all VLANs onto one wire.

```
                        ┌──────────────────────────────────────────────┐
                        │            TL-SG2008 Switch                  │
                        │                                              │
  Port 1  ──────────────┤ ACCESS PVID=10 ◀── VLAN 10 only             │
  (PC, VLAN 10)         │   untagged in/out                            │
                        │                                              │
  Port 2  ──────────────┤ ACCESS PVID=20 ◀── VLAN 20 only             │
  (IoT, VLAN 20)        │   untagged in/out                            │
                        │                                              │
  Port 3  ──────────────┤ ACCESS PVID=10 ◀── VLAN 10 only             │
  (Server, VLAN 10)     │   untagged in/out                            │
                        │                                              │
  Port 8  ──────────────┤ TRUNK                                        │
  (uplink to Proxmox)   │   Tagged VLAN 10 ──▶ [frame | VID=10]       │
                        │   Tagged VLAN 20 ──▶ [frame | VID=20]       │
                        │   both VLANs on one wire simultaneously      │
                        └──────────────────────────────────────────────┘
                                              │
                                              │  one physical cable
                                              │  carries VLAN 10 + VLAN 20
                                              ▼
                                     Proxmox vmbr1 (VLAN-aware)
                                     ├── vtnet1_vlan10 → OPNsense LAN10
                                     └── vtnet1_vlan20 → OPNsense OPT2

Without trunk:  2 VLANs → 2 physical cables from switch to server
With trunk:     2 VLANs → 1 physical cable, tags distinguish them
```

---

### 3.5 Bridge VLAN-Awareness — Before and After

This is the most critical concept for the Option B setup. The bridge's behavior determines whether VLAN tags survive the journey from OPNsense to the physical switch.

```
VLAN-UNAWARE bridge (default Proxmox):      VLAN-AWARE bridge (bridge-vlan-aware yes):
──────────────────────────────────────      ──────────────────────────────────────────

OPNsense vtnet1_vlan10                      OPNsense vtnet1_vlan10
  emits [frame | VID=10]                      emits [frame | VID=10]
         │                                           │
         ▼                                           ▼
  tap101i1 (virtual cable)                    tap101i1 (virtual cable)
         │                                           │
         │  tag arrives at bridge                    │  tag arrives at bridge
         ▼                                           ▼
  vmbr1 STRIPS tag ✗                          vmbr1 PASSES tag through ✓
         │                                           │
         ▼                                           ▼
  enx... receives [frame]                     enx... receives [frame | VID=10]
  (plain untagged frame —                     (tag is intact — switch can
   tag is permanently lost)                    read the VLAN ID)
         │                                           │
         ▼                                           ▼
  SG2008 port 8 sees                          SG2008 port 8 sees
  untagged frame                              tagged frame VID=10
         │                                           │
         ▼                                           ▼
  port 8 PVID assigns it                      Tagged VLAN 10 member
  to PVID's VLAN (e.g. VLAN 1)               routes to VLAN 10 domain ✓
         │
         ▼
  WRONG VLAN — devices on VLAN 10
  never receive the frame
  (or worse: you reach the switch
   mgmt on VLAN 1 instead, causing
   apparent connectivity that hides
   the real VLAN failure)
```

**Bottom line:** enabling `VLAN-aware` on the bridge is the mandatory prerequisite for Option B. Without it, all VLAN tag work in OPNsense is invisible to the switch.

---

### 3.6 Lockout Scenario — Step-by-Step State Diagram

This shows what happens when you change the LAN interface assignment without first enabling bridge VLAN-awareness.

```
Initial state (working):
┌────────────────┐     ┌───────────────────┐     ┌──────────────┐
│ OPNsense LAN   │     │ Proxmox vmbr1     │     │ SG2008       │
│ = vtnet1       │────▶│ VLAN-unaware      │────▶│ port 8 PVID1 │
│ 10.0.0.1/24    │     │ passes untagged   │     │ sees untagged│
│ anti-lockout ✓ │     │ frames fine       │     │ assigns VLAN1│
└────────────────┘     └───────────────────┘     └──────────────┘
     WebGUI: ✓              DHCP: ✓                  LAN: ✓

Step 1 — You change LAN to vtnet1_vlan10 in Interfaces → Assignments:
┌────────────────┐     ┌───────────────────┐     ┌──────────────┐
│ OPNsense LAN   │     │ Proxmox vmbr1     │     │ SG2008       │
│ = vtnet1_vlan10│────▶│ VLAN-unaware ✗   │────▶│ port 8       │
│ 10.0.0.1/24    │     │ strips VID=10 tag │     │ sees untagged│
│ anti-lockout ✓ │     │ before forwarding │     │ (no VID=10)  │
└────────────────┘     └───────────────────┘     └──────────────┘
     │                       │                        │
     ▼                       ▼                        ▼
vtnet1_vlan10 only      tag is gone —           frame arrives in
accepts VID=10 frames   vtnet1_vlan10 sees      wrong VLAN
                        nothing                  devices unreachable

Step 2 — Cascading failures:
  LAN interface: DARK (receives no valid frames)
       │
       ├──▶ DHCP server: no responses (LAN interface down)
       │
       ├──▶ Anti-lockout rule: fires on dead interface — no effect
       │         WebGUI on 10.0.0.1: UNREACHABLE from LAN
       │
       └──▶ WAN WebGUI: no pass rule exists by default
                 WebGUI on 192.168.1.101: UNREACHABLE from WAN

Final state: LOCKED OUT — console access required (see Section 5)
```

---

### 3.7 Option A Full-Stack Diagram — Frame State at Every Segment

Each arrow shows what is on the wire at that point, with VLAN state and IP context.

```
OPNsense VM (VM 101)
┌────────────────────────────────────────────────────┐
│  vtnet1  IP: 10.0.0.1/24                           │
│  LAN interface — sends/receives UNTAGGED frames     │
└────────────────────────┬───────────────────────────┘
                         │ wire: UNTAGGED frame (no VID)
                         │ e.g.: src=10.0.0.1, dst=10.0.0.50
                         ▼
Proxmox Host
┌────────────────────────────────────────────────────┐
│  tap101i1 (virtual cable from VM 101 vtnet1)        │
│         │                                           │
│         ▼                                           │
│  vmbr1  (VLAN-unaware, default)                    │
│  action: forward frame unchanged (no tags to strip) │
│         │                                           │
│         ▼                                           │
│  enx1c860b363f63  (physical NIC)                   │
└────────────────────────┬───────────────────────────┘
                         │ wire: UNTAGGED frame
                         │ (same frame, no modification)
                         ▼
TL-SG2008 Switch
┌────────────────────────────────────────────────────┐
│  Port 8 (uplink from Proxmox)                       │
│    PVID=10, untagged member of VLAN 10              │
│    action: ingress untagged → assign VID=10         │
│    internally: [frame | VID=10]                     │
│         │                                           │
│         ▼ (internal switch fabric, VLAN 10)         │
│  Ports 1–7 (device ports)                           │
│    PVID=10, untagged member of VLAN 10              │
│    action: egress strip VID=10 tag                  │
└────────────────────────┬───────────────────────────┘
                         │ wire: UNTAGGED frame
                         │ dst=10.0.0.50 receives it
                         ▼
End device (10.0.0.50) — receives normal untagged Ethernet frame
```

---

### 3.8 Option B Full-Stack Diagram — Frame State at Every Segment

```
OPNsense VM (VM 101)
┌────────────────────────────────────────────────────┐
│  vtnet1_vlan10  IP: 10.0.0.1/24                    │
│  LAN interface — sends/receives frames tagged VID=10│
└────────────────────────┬───────────────────────────┘
                         │ wire: TAGGED frame [VID=10]
                         │ 802.1Q header inserted after src MAC
                         ▼
Proxmox Host
┌────────────────────────────────────────────────────┐
│  tap101i1 (virtual cable from VM 101 vtnet1)        │
│         │                                           │
│         ▼                                           │
│  vmbr1  (VLAN-aware: bridge-vlan-aware yes)         │
│  action: PASS tag through unchanged ✓               │
│         │                                           │
│         ▼                                           │
│  enx1c860b363f63  (physical NIC)                   │
└────────────────────────┬───────────────────────────┘
                         │ wire: TAGGED frame [VID=10]
                         │ tag intact — switch will read it
                         ▼
TL-SG2008 Switch
┌────────────────────────────────────────────────────┐
│  Port 8 (uplink from Proxmox)                       │
│    Tagged member of VLAN 10 (trunk port)            │
│    action: accept tagged frame, read VID=10         │
│    internally: route to VLAN 10 domain              │
│         │                                           │
│         ▼ (internal switch fabric, VLAN 10)         │
│  Ports 1–7 (device ports)                           │
│    PVID=10, untagged member of VLAN 10              │
│    action: egress strip VID=10 tag                  │
└────────────────────────┬───────────────────────────┘
                         │ wire: UNTAGGED frame
                         │ dst=10.0.0.50 receives it
                         ▼
End device (10.0.0.50) — receives normal untagged Ethernet frame

Future VLAN expansion (Option B only):
  Add vtnet1_vlan20 in OPNsense → same vmbr1 bridge →
  switch port 8 carries [VID=10] and [VID=20] simultaneously →
  new access ports with PVID=20 serve IoT/etc.
  Zero hardware changes needed.
```

---

## 4. Why the Lockout Happens

**Scenario:** You go to `Interfaces → Assignments` in OPNsense and change LAN from `vtnet1` to `vtnet1_vlan10`.

### What breaks immediately

1. OPNsense's LAN interface is now `vtnet1_vlan10`, which only processes frames tagged with VLAN ID 10.
2. The Proxmox bridge `vmbr1` is still VLAN-unaware — it does not pass tags through.
3. Every frame arriving at `vtnet1_vlan10` from the bridge has **no VLAN tag** — they are all dropped.
4. OPNsense's LAN interface is effectively dark: no DHCP responses, no routing, no WebGUI on 10.0.0.1.

### Why WAN-side WebGUI also stops working

OPNsense has an **anti-lockout rule** — an automatically generated firewall rule that allows WebGUI access from the LAN interface. When LAN goes dark:

- The anti-lockout rule is attached to the (now dead) LAN interface — it has no effect.
- By default there is **no pass rule for WAN → WebGUI** (port 443/80).
- OPNsense's default WAN behavior is to block all unsolicited inbound traffic.
- Result: WebGUI inaccessible from 192.168.1.101 as well.

**You are now locked out from both sides.** Console access is the only path to recovery.

---

## 5. Recovery: Restore OPNsense Access via Proxmox Console

This procedure requires no network access to OPNsense. It uses the Proxmox web UI (accessible at `https://192.168.1.110:8006`).

### Step 1 — Open the console

```
Proxmox UI → Datacenter → pve → VM 101 (home-router) → Console button
```

This opens a noVNC browser console directly connected to the VM's virtual monitor.

### Step 2 — Log in

At the OPNsense console login prompt:

```
login: root
Password: opnsense    (default — change this if you set a custom root password)
```

The numbered console menu appears:

```
 0) Logout
 1) Assign Interfaces
 2) Set Interface IP address
 3) Reset the root password
 4) Reset to factory defaults
 5) Power off system
 6) Reboot system
 7) Ping host
 8) Shell
 9) pfTop
10) Filter logs
11) Restart web configurator
12) PHP interactive shell
13) Update from console
14) Disable/Enable Secure Shell (SSH)
15) Restore a backup
16) Restart all services
```

### Step 3 — Re-assign LAN to vtnet1 (Option 1)

Select option **1 — Assign Interfaces**.

When prompted, do not set up VLANs (answer `n`):

```
Do you want to set up VLANs now? [y|n]: n
```

Follow the prompts:

```
Enter the WAN interface name or 'a' for auto-detection: vtnet0
Enter the LAN interface name or 'a' for auto-detection: vtnet1
Enter the Optional 1 interface name or 'a' for auto-detection: [press Enter to skip]
```

Confirm the assignment. OPNsense will apply the change immediately — LAN comes back on `vtnet1`.

### Step 4 — Set the LAN IP (Option 2)

Select option **2 — Set Interface IP address**.

```
Enter the number of the interface to configure: 2    (or whichever number maps to LAN/vtnet1)
Enter the new LAN IPv4 address: 10.0.0.1
Enter the new LAN IPv4 subnet bit count (1 to 32): 24
For a WAN, enter the new LAN IPv4 upstream gateway address: [press Enter — no gateway on LAN]
Do you want to enable the DHCP server on LAN? [y|n]: y
Enter the start address of the IPv4 client address range: 10.0.0.100
Enter the end address of the IPv4 client address range: 10.0.0.200
```

### Step 5 — Verify

After applying:

- WebGUI should restore at `https://10.0.0.1` (from a device on LAN)
- Or `https://192.168.1.101` (from WAN/Proxmox host) — anti-lockout rule re-activates when LAN is healthy

If the web UI is still not accessible from WAN, try option **11 — Restart web configurator** from the console menu.

### Alternative: Edit config.xml via shell

If the console menu is unresponsive or the assignment prompts don't appear, use option **8 — Shell**:

```bash
viconfig
```

This opens `/conf/config.xml` in the `vi` editor. Find the LAN interface block and revert the `<if>` tag:

```xml
<!-- Change this: -->
<if>vtnet1_vlan10</if>

<!-- Back to this: -->
<if>vtnet1</if>
```

Save (`:wq`) and restart OPNsense services from the shell:

```bash
/etc/rc.reload_all
```

---

## 6. Option A: Single VLAN, No Trunk (Recommended)

Best for a single-subnet homelab. OPNsense LAN stays on `vtnet1` (untagged). VLAN 10 is a switch-internal concept only. No Proxmox changes needed.

### Architecture

```
OPNsense LAN = vtnet1 (untagged), 10.0.0.1/24   ← no change
       |
Proxmox vmbr1 (VLAN-unaware, no changes needed)
       |
enx1c860b363f63 (physical NIC)
       |
SG2008 port 8: untagged member of VLAN 10, PVID=10
SG2008 ports 1–7: untagged member of VLAN 10, PVID=10
```

### Step A1 — OPNsense: Confirm LAN is vtnet1

In OPNsense WebGUI:

```
Interfaces → Assignments
```

Confirm `LAN` maps to `vtnet1` (not vtnet1_vlan10). If vtnet1_vlan10 exists as an OPT interface from a previous setup, you can delete it under `Interfaces → Other Types → VLAN`.

### Step A2 — OPNsense: Confirm LAN IP and DHCP

```
Interfaces → [LAN]
  IPv4 Configuration Type: Static IPv4
  IPv4 Address: 10.0.0.1 / 24
  Save → Apply Changes
```

```
Services → DHCPv4 → [LAN]
  Enable: ✓
  Range: 10.0.0.100 – 10.0.0.200
  DNS Servers: 10.0.0.1
  Save
```

### Step A3 — OPNsense: Add static DHCP lease for switch

```
Services → DHCPv4 → [LAN] → Static Mappings → Add
  MAC Address: (printed on SG2008 label, format xx:xx:xx:xx:xx:xx)
  IP Address: 10.0.0.2
  Hostname: sg2008-switch
  Save
```

### Step A4 — SG2008: Create VLAN 10

Log into the SG2008 web UI. Default IP before any configuration: `http://192.168.0.1` (admin / admin).

```
L2 FEATURES → 802.1Q VLAN → VLAN Config → Add
  VLAN ID: 10
  Name: homelab-lan
```

### Step A5 — SG2008: Configure port membership

```
L2 FEATURES → 802.1Q VLAN → VLAN Config → Edit VLAN 10
  Port 8 (uplink): Untagged    ← access port, not trunk
  Ports 1–7:       Untagged
```

```
L2 FEATURES → 802.1Q VLAN → Port Config
  Port 8:    PVID = 10
  Ports 1–7: PVID = 10
```

This makes every port an untagged access port in VLAN 10. Frames flow between OPNsense and devices with no VLAN tags anywhere — exactly what `vtnet1` (untagged LAN) expects.

### Step A6 — SG2008: Set management VLAN and IP

```
L3 Features → Interface
  Click "Edit IPv4" on the VLAN 10 row (create VLAN 10 interface first if it doesn't exist)
  IP Address Mode: Static
  IP Address: 10.0.0.2
  Subnet Mask: 255.255.255.0
  Click Apply, then Save
```

> **Note:** The TL-SG2008 V3 / newer firmware uses L3 Features → Interface instead of SYSTEM → System IP. There is no explicit gateway field — the management VLAN is implicitly whichever VLAN interface has an IP assigned. See [TP-Link FAQ 2122](https://www.tp-link.com/us/support/faq/2122/) for details.

The switch drops its 192.168.0.x address. After saving, reconnect at `http://10.0.0.2` from a device on the 10.0.0.0/24 network (or via OPNsense WebGUI proxy if needed).

### Verification

1. Ping the switch: `ping 10.0.0.2` from a device on LAN
2. Check OPNsense DHCP leases: `Services → DHCPv4 → Leases` — confirm the switch lease appears
3. Access switch UI at `http://10.0.0.2`

---

## 7. Option B: VLAN Trunk (Multi-VLAN Ready)

Use this when you need multiple VLANs (e.g., homelab, IoT, management) on the same physical uplink. Frames are tagged between OPNsense and the switch.

**Critical: follow the steps in this exact order.** Deviating from the sequence is how lockouts happen.

### Architecture

```
OPNsense vtnet1_vlan10 (tagged, VLAN 10), 10.0.0.1/24
       |
Proxmox vmbr1 (VLAN-aware — MUST be done first)
       |
enx1c860b363f63 (physical NIC)
       |
SG2008 port 8: Tagged VLAN 10 (trunk uplink)
SG2008 ports 1–7: Untagged VLAN 10, PVID=10
```

### Step B1 — Proxmox: Enable VLAN-aware on vmbr1 (DO THIS FIRST)

**Do not touch OPNsense until this is confirmed.**

**Option 1 — Via Proxmox UI:**

```
Proxmox UI → System → Network → vmbr1 → Edit
  VLAN aware: ✓ (check the box)
  OK → Apply Configuration
```

**Option 2 — Via shell on Proxmox host:**

Edit `/etc/network/interfaces`, find the vmbr1 stanza, add `bridge-vlan-aware yes`:

```bash
# /etc/network/interfaces — vmbr1 stanza (example)
iface vmbr1 inet manual
    bridge-ports enx1c860b363f63 fwpr100p0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes   # add this line
```

Apply without reboot:

```bash
ifreload -a
```

Verify:

```bash
bridge vlan show dev vmbr1
# Should show vlan entries if VLAN-aware is active
```

### Step B2 — OPNsense: Create VLAN 10 subinterface (keep LAN intact)

In OPNsense WebGUI:

```
Interfaces → Other Types → VLAN → Add
  Parent Interface: vtnet1
  VLAN Tag: 10
  VLAN Priority: (leave default)
  Description: homelab-lan
  Save
```

This creates `vtnet1_vlan10` but does **not** assign it to any interface yet. LAN is still `vtnet1` — you are not locked out.

### Step B3 — OPNsense: Assign vtnet1_vlan10 as OPT1

```
Interfaces → Assignments → Add (bottom of list)
  Available network ports: select vtnet1_vlan10
  Add → gives it OPT1 name
```

Click on OPT1 to configure it:

```
Interfaces → [OPT1]
  Enable: ✓
  Description: LAN10
  IPv4 Configuration Type: Static IPv4
  IPv4 Address: 10.0.0.1 / 24    ← temporarily use a different IP like 10.0.0.254/24 if LAN is already 10.0.0.1
  Save → Apply Changes
```

> Note: Two interfaces cannot share the same /24 subnet in OPNsense. During transition, assign LAN10 a temporary IP (e.g., 10.0.0.254/24), verify connectivity, then remove the original LAN and reassign 10.0.0.1/24 to LAN10.

### Step B4 — OPNsense: Enable DHCP on LAN10

```
Services → DHCPv4 → [LAN10] → Enable
  Range: 10.0.0.100 – 10.0.0.200
  DNS Servers: 10.0.0.1 (or 10.0.0.254 during transition)
  Save
```

### Step B5 — SG2008: Configure tagged uplink

In the SG2008 web UI:

```
L2 FEATURES → 802.1Q VLAN → VLAN Config → Add
  VLAN ID: 10
  Name: homelab-lan

Edit VLAN 10 port membership:
  Port 8 (uplink to Proxmox): Tagged
  Ports 1–7 (device ports):   Untagged
```

```
L2 FEATURES → 802.1Q VLAN → Port Config
  Port 8:    PVID = 1   (keep native VLAN 1 on uplink during transition)
  Ports 1–7: PVID = 10
```

### Step B6 — Verify LAN10 reachable before cutting over

From a device on VLAN 10 (connected to switch ports 1–7):

```bash
ping 10.0.0.254   # or whatever IP you assigned to LAN10
```

Confirm a DHCP lease is issued from the LAN10 range.

**Do not proceed until this is confirmed working.**

### Step B7 — Cut over: remove original LAN, reassign LAN10

Only after Step B6 is confirmed:

1. Remove the original LAN interface (or change it to a non-conflicting subnet):
   ```
   Interfaces → [LAN] → Disable (uncheck Enable) → Save → Apply
   ```

2. Reassign LAN10 to 10.0.0.1/24:
   ```
   Interfaces → [LAN10] → IPv4 Address: 10.0.0.1 / 24 → Save → Apply
   ```

3. Update DHCP DNS/gateway to 10.0.0.1:
   ```
   Services → DHCPv4 → [LAN10] → DNS Servers: 10.0.0.1, Gateway: 10.0.0.1 → Save
   ```

4. Update SG2008 port 8 PVID if needed:
   ```
   L2 FEATURES → 802.1Q VLAN → Port Config → Port 8: PVID = 10
   ```

5. Set SG2008 management VLAN and IP:
   ```
   L3 Features → Interface → Edit IPv4 on VLAN 10 → Static, IP: 10.0.0.2, Mask: 255.255.255.0 → Apply → Save
   ```

### Step B8 — OPNsense: Add static DHCP lease for switch

```
Services → DHCPv4 → [LAN10] → Static Mappings → Add
  MAC: (SG2008 MAC from switch label)
  IP: 10.0.0.2
  Hostname: sg2008-switch
  Save
```

---

## 8. OPNsense 25.7 Specific Notes

### Menu paths

OPNsense 25.7 uses the same navigation structure as 23.x/24.x. Key paths:

| Action | Path |
|---|---|
| View interface assignments | Interfaces → Assignments |
| Create VLAN subinterface | Interfaces → Other Types → VLAN |
| Firewall rules (per-interface) | Firewall → Rules → [Interface name] |
| DHCP server | Services → DHCPv4 → [Interface name] |
| DHCP leases | Services → DHCPv4 → Leases |
| Anti-lockout rule | System → Settings → Administration → Anti-Lockout |

### Anti-lockout rule behavior

The anti-lockout rule is automatically maintained by OPNsense. It lives on the LAN interface (the one with the lowest-numbered assignment, typically the first one in `Interfaces → Assignments`). It allows WebGUI access (TCP 443/80) from any LAN source.

- If LAN goes dark (misconfigured VLAN), the anti-lockout rule has no active interface to fire on — WebGUI becomes inaccessible from LAN.
- OPNsense does **not** add a WAN pass rule for WebGUI by default. If you need WAN WebGUI access, add a firewall rule manually under `Firewall → Rules → WAN`.
- After restoring LAN, the anti-lockout rule re-activates automatically — no manual action needed.

### DHCP server for VLAN interfaces

In OPNsense 25.7, DHCP server configuration is per-interface. After assigning vtnet1_vlan10 as an interface (LAN10), the DHCPv4 tab for LAN10 appears under `Services → DHCPv4 → [LAN10]`. You must enable it explicitly — DHCP is not enabled by default on new OPT interfaces.

### Firewall rules on new VLAN interfaces

When you assign a new OPT interface, it has **no firewall rules by default** — all traffic on that interface is blocked. You must add at least one pass rule:

```
Firewall → Rules → [LAN10] → Add
  Action: Pass
  Interface: LAN10
  Protocol: Any
  Source: LAN10 net
  Destination: Any
  Description: Allow all LAN10 outbound
  Save → Apply Changes
```

---

## 9. Verification Checklist

### After Option A (No Trunk)

- [ ] OPNsense WebGUI accessible at `https://10.0.0.1` from a device on LAN
- [ ] `ping 10.0.0.1` succeeds from a device connected to SG2008 ports 1–7
- [ ] DHCP lease issued to a test device (check `Services → DHCPv4 → Leases`)
- [ ] `ping 10.0.0.2` succeeds (switch management IP — may need to wait for DHCP renewal)
- [ ] SG2008 web UI accessible at `http://10.0.0.2`
- [ ] OPNsense can reach internet from a LAN device (test with `curl https://example.com`)

### After Option B (Trunk)

- [ ] All Option A checks above
- [ ] Confirm vmbr1 is VLAN-aware: `bridge vlan show dev vmbr1` on Proxmox host shows VLAN 10 entries
- [ ] Tagged frames passing: `tcpdump -i enx1c860b363f63 vlan` on Proxmox host should show VLAN-tagged traffic
- [ ] SG2008 port 8 shows as Tagged member of VLAN 10 in switch VLAN config
- [ ] No duplicate subnet conflict in OPNsense (`Interfaces → Overview` — no two interfaces on same /24)
- [ ] DHCP leases are coming from LAN10, not the old LAN interface

### Talos CP1 specific

- [ ] `BC:24:11:FC:76:0A` appears in `Services → DHCPv4 → Leases` with IP `10.0.0.10`
- [ ] `talosctl --talosconfig=./talosconfig config endpoint 10.0.0.10` does not time out
- [ ] `talosctl health` returns OK for CP1

---

## 10. Troubleshooting

### 10.1 Can't Reach the Switch at Default IP (192.168.0.1)

If you're at step A4 or B5 and can't access the SG2008 web UI at `http://192.168.0.1`, work through these causes in order:

**Subnet mismatch — most common cause**

Your computer is on a different subnet (e.g., 10.0.0.x or 192.168.1.x) and can't reach 192.168.0.1 without a router. You need to temporarily set a static IP in the 192.168.0.x range:

- **macOS:**
  ```bash
  # Set static IP on Ethernet interface
  networksetup -setmanual "Ethernet" 192.168.0.100 255.255.255.0 192.168.0.1

  # When done, revert to DHCP
  networksetup -setdhcp "Ethernet"
  ```
  > Tip: Run `networksetup -listallnetworkservices` to find the exact interface name. It may be "USB 10/100/1000 LAN" or similar for USB-C adapters.

- **Linux:**
  ```bash
  # Find your ethernet interface name
  ip link show

  # Add a static IP (replace eth0 with your interface)
  sudo ip addr add 192.168.0.100/24 dev eth0

  # When done, remove it
  sudo ip addr del 192.168.0.100/24 dev eth0
  ```

- **Windows:**
  ```
  Settings → Network & Internet → Ethernet → Edit IP settings
  Set to Manual → IPv4 On
  IP: 192.168.0.100, Subnet: 255.255.255.0, Gateway: 192.168.0.1
  ```

**Wrong port**

Connect your cable to port 1 on the switch, not port 8. Some managed switches reserve the last port for uplinks and may behave differently with default settings.

**Switch IP was already changed**

If someone (or a previous configuration attempt) already changed the switch's management IP, 192.168.0.1 won't respond. Try scanning the subnet your switch might be on:

```bash
# Scan the default subnet
nmap -sn 192.168.0.0/24

# Also try the homelab subnet if the switch was partially configured
nmap -sn 10.0.0.0/24
```

**Cable goes through Proxmox instead of direct connection**

The switch must be connected directly to your laptop/PC with an Ethernet cable for initial setup. If the cable goes laptop → Proxmox NIC → vmbr1 → switch, your traffic passes through the Proxmox bridge and OPNsense routing, which won't route to 192.168.0.x. Use a direct cable.

**Factory reset**

If nothing else works, factory reset the switch:

1. With the switch powered on, press and hold the **Reset** button (small pinhole on the back) for **5–10 seconds**
2. All port LEDs will flash briefly — release the button
3. Wait 30 seconds for the switch to reboot
4. Try `http://192.168.0.1` again (default credentials: admin / admin)

**Diagnostic checklist**

```bash
# 1. Check your own IP — are you on 192.168.0.x?
ip addr show          # Linux/macOS
ipconfig              # Windows

# 2. Check if the switch responds at L2 (even if IP is wrong)
arp -a | grep -i "192.168.0"

# 3. Verify the physical link is up
ip link show          # Look for "state UP" on your ethernet interface

# 4. Check the link light on the switch port — is it lit?
```

### 10.2 Lost Access to Switch After Changing Management VLAN/IP

After step A6 or B7 (changing the switch management VLAN to 10 and IP to 10.0.0.2), the switch is no longer reachable at 192.168.0.1. This is expected, but there's a dead zone between saving the new config and being able to reach the switch on the new IP.

**To reconnect:**

1. Ensure your device is on the 10.0.0.0/24 subnet (either via DHCP from OPNsense, or a static IP like 10.0.0.100)
2. Try `http://10.0.0.2` — the switch should respond on its new IP
3. If it doesn't respond, check that OPNsense is routing on the LAN interface and DHCP is active

**If you're completely stuck:**

Factory reset the switch (see 10.1) and start the switch configuration steps over. The OPNsense side doesn't need to change — only the switch config is lost on reset.

### 10.3 OPNsense WebGUI Unreachable After VLAN Change

If you changed the LAN interface to `vtnet1_vlan10` and lost WebGUI access, this is the lockout scenario described in [Section 4](#4-why-the-lockout-happens).

**Quick checklist:**

1. **Is vmbr1 VLAN-aware?** If not, tags are stripped and vtnet1_vlan10 receives nothing. See [Section 5](#5-recovery-restore-opnsense-access-via-proxmox-console) for recovery.
2. **Is LAN still assigned to vtnet1?** Check via Proxmox console → OPNsense console menu → Option 1.
3. **Can you reach Proxmox?** Go to `https://192.168.1.110:8006` and use the VM console to fix OPNsense.

### 10.4 Devices on Switch Can't Get DHCP

If devices connected to the SG2008 aren't getting IP addresses:

**Check OPNsense DHCP is enabled on the correct interface**

```
Services → DHCPv4 → [LAN] (or [LAN10] for Option B)
```

Verify "Enable" is checked and the range is set (e.g., 10.0.0.100–10.0.0.200).

**Check firewall rules on OPT interfaces**

New OPT interfaces (like LAN10 in Option B) have **no firewall rules by default** — all traffic is blocked, including DHCP. Add a pass rule:

```
Firewall → Rules → [LAN10] → Add
  Action: Pass
  Protocol: Any
  Source: LAN10 net
  Destination: Any
  Save → Apply Changes
```

**Check switch port PVID**

Every device port must have its PVID set to the VLAN where DHCP is served. If ports 1–7 have PVID=1 (default) but DHCP is on VLAN 10, devices will land in VLAN 1 and never see DHCP responses.

```
L2 FEATURES → 802.1Q VLAN → Port Config
  Ports 1–7: PVID = 10
```

---

## 11. Networking Prerequisites & Tools

This section covers the foundational networking concepts and tools you'll need to work through this guide. If you're new to VLANs and network configuration, start here.

### 11.1 Essential Concepts to Understand First

**IP Addressing & Subnetting**

Every device on a network needs an IP address. The `/24` in `10.0.0.0/24` means the first 24 bits are the network address — so all IPs from 10.0.0.1 to 10.0.0.254 are on the same subnet. Devices on 192.168.0.x **cannot talk to** devices on 10.0.0.x without a router in between. This is why you can't reach a switch at 192.168.0.1 when your laptop is on 10.0.0.x.

**MAC Addresses**

A MAC address (e.g., `BC:24:11:FC:76:0A`) is a hardware identifier burned into every network interface. Switches use MAC addresses to forward frames at Layer 2 — they learn which MAC is on which port and only send frames where they need to go. MAC addresses are relevant when setting up static DHCP leases (you're telling OPNsense "always give this MAC this IP").

**ARP (Address Resolution Protocol)**

ARP is how devices discover the MAC address behind an IP address. When your laptop wants to reach 10.0.0.1, it broadcasts "who has 10.0.0.1?" and OPNsense replies with its MAC. The `arp -a` command shows your device's ARP cache — a table of IP-to-MAC mappings it has learned. This is useful for debugging: if the switch doesn't appear in `arp -a`, your device has never successfully communicated with it at Layer 2.

**DHCP (Dynamic Host Configuration Protocol)**

DHCP automatically assigns IP addresses to devices. OPNsense runs the DHCP server and hands out IPs from a configured range (e.g., 10.0.0.100–200). The lifecycle: device connects → sends DHCP Discover broadcast → OPNsense responds with an IP offer → device accepts. Leases expire and get renewed. Static mappings let you pin a specific IP to a specific MAC address.

**Default Gateway**

The default gateway is the IP a device sends traffic to when the destination is outside its own subnet. For devices on 10.0.0.0/24, the gateway is 10.0.0.1 (OPNsense). Without a gateway, devices can only talk to others on the same subnet.

**DNS (Domain Name System)**

DNS translates names like `example.com` into IP addresses. When testing connectivity, use `ping` with an IP address first (e.g., `ping 8.8.8.8`) to rule out DNS issues. If IP pings work but name resolution doesn't, the problem is DNS, not routing.

### 11.2 Debugging Tools Reference

| Tool | What it does | Example | When to use |
|------|-------------|---------|-------------|
| `ping` | Tests basic IP reachability | `ping 10.0.0.1` | First thing to try — does the device respond? |
| `arp -a` | Shows known MAC-to-IP mappings | `arp -a \| grep 192.168.0` | Check if the switch is visible at Layer 2, even if ping fails |
| `ip addr` / `ifconfig` | Shows your own IP addresses and interface state | `ip addr show` | Verify you're on the right subnet |
| `ip link show` | Shows interface link state (up/down) | `ip link show eth0` | Check if the physical link is up |
| `nmap -sn` | Discovers live devices on a subnet | `nmap -sn 192.168.0.0/24` | Find a device when you don't know its IP |
| `tcpdump` | Captures packets on an interface | `tcpdump -i eth0 -n arp` | See what's actually happening on the wire |
| `curl` | Tests HTTP access | `curl -k https://10.0.0.1` | Verify web UI is responding |
| `traceroute` | Shows the path packets take | `traceroute 10.0.0.1` | Diagnose where packets are getting dropped |

**macOS-specific: Setting a static IP**

```bash
# List network services to find the right interface name
networksetup -listallnetworkservices

# Set static IP for initial switch access
networksetup -setmanual "Ethernet" 192.168.0.100 255.255.255.0 192.168.0.1

# Revert to DHCP when done
networksetup -setdhcp "Ethernet"
```

### 11.3 Recommended Learning Resources

**Networking Fundamentals**

- [Practical Networking](https://www.practicalnetworking.net/) — clear explanations of subnetting, VLANs, and the OSI model (blog + YouTube)
- [NetworkChuck](https://www.youtube.com/@NetworkChuck) — beginner-friendly VLAN and subnetting video walkthroughs
- [Jeremy's IT Lab](https://www.youtube.com/@JesijsITlab) — free CCNA-level networking course on YouTube
- [Julia Evans' networking zines](https://wizardzines.com/) — visual, bite-sized explanations of networking concepts

**Tools**

- [ipcalc](https://jodies.de/ipcalc) — online subnet calculator (helps visualize what /24 means)
- [nmap](https://nmap.org/) — network scanner for device discovery

**Product Documentation**

- [OPNsense — VLANs](https://docs.opnsense.org/manual/how-tos/vlan_and_lagg.html) — official VLAN setup guide
- [OPNsense — Firewall Rules](https://docs.opnsense.org/manual/firewall.html) — understanding pass/block rules
- [TP-Link Omada Knowledge Base](https://www.tp-link.com/us/support/faq/2149/) — 802.1Q VLAN setup on managed switches

---

## 12. References

### This Homelab

- [Homelab Current State](./homelab-current-state.md) — infrastructure snapshot, network topology, known issues
- [Talos Setup Guide](./talos-setup-guide.md) — Talos bootstrap steps (depends on LAN being reachable)
- [Architecture Diagrams](./architecture-diagrams.md) — full topology diagrams

### VLAN + OPNsense Guides

- [VLAN from Scratch — OPNsense + Proxmox + Switch](https://koromatech.com/vlan-setup-from-scratch-opnsense-proxmox-switch-complete-guide/) — koromatech.com
- [OPNsense + Proxmox VLAN trunk setup](https://forum.proxmox.com/threads/help-with-proxmox-trunk-port-setup-%E2%80%93-letting-opnsense-handle-vlans-dhcp-etc.167426/) — Proxmox forum
- [IoT VLAN with OPNsense + TP-Link Omada](https://www.gaelanlloyd.com/blog/iot-vlan-opnsense-omada-ipv6/) — gaelanlloyd.com

### Official Documentation

- [OPNsense — VLAN and LAGG setup](https://docs.opnsense.org/manual/how-tos/vlan_and_lagg.html)
- [Proxmox — Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)
- [TP-Link — 802.1Q VLAN on Omada switches with 3rd-party router](https://www.tp-link.com/us/support/faq/4084/)
- [TP-Link — 802.1Q VLAN on Smart/Managed switches](https://www.tp-link.com/us/support/faq/2149/)
