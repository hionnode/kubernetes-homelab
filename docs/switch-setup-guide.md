# TL-SG2008 Initial Setup from macOS

**Environment:** macOS (Apple Silicon / M1) · USB-C hub with Ethernet · TP-Link TL-SG2008 (Omada)
**Scope:** First-time access to the switch from a Mac laptop via direct Ethernet connection.

> For VLAN configuration after initial access, see [opnsense-vlan-setup.md](./opnsense-vlan-setup.md).

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Find Your Ethernet Interface](#2-find-your-ethernet-interface)
3. [Set a Static IP on the Switch's Subnet](#3-set-a-static-ip-on-the-switchs-subnet)
4. [Test Connectivity](#4-test-connectivity)
5. [Factory Reset](#5-factory-reset)
6. [Access the Switch Web UI](#6-access-the-switch-web-ui)
7. [Configure for Homelab (Quick Reference)](#7-configure-for-homelab-quick-reference)
8. [Clean Up Mac Network Settings](#8-clean-up-mac-network-settings)
9. [Troubleshooting Quick Reference](#9-troubleshooting-quick-reference)
10. [References](#10-references)

---

## 1. Prerequisites

- TL-SG2008 powered on (check power LED is solid green)
- Ethernet cable — **direct** from laptop to switch (NOT through Proxmox or another router)
- USB-C hub with Ethernet port plugged into the Mac
- Connect to **port 1** on the switch (not port 8, which is typically the uplink)

---

## 2. Find Your Ethernet Interface

macOS with USB-C hubs creates Ethernet interfaces dynamically, and the standard tools don't always show them. This section walks through the exact process.

### List known network services

```bash
networksetup -listallnetworkservices
```

Look for a name like `USB 10/100/1000 LAN` or `USB 10/100 LAN` — **not** `Ethernet`. The exact name depends on your USB-C hub's chipset.

### Map service names to device names

```bash
networksetup -listallhardwareports
```

This maps each service name to its `enX` device. Example output:

```
Hardware Port: USB 10/100/1000 LAN
Device: en7
Ethernet Address: xx:xx:xx:xx:xx:xx
```

**The USB-C hub gotcha:** Dynamically created interfaces (e.g., `en8`) may **not** appear in `listallhardwareports` output. This is normal on Apple Silicon Macs with USB-C hubs. If your USB-C hub's Ethernet doesn't show up here, skip to the next step.

### Find the active interface directly

```bash
ifconfig | grep -E "^en|status:"
```

Look for the `enX` interface that shows `status: active`. That's your USB-C hub's Ethernet adapter.

If no interface shows active: unplug and replug the USB-C hub, wait a few seconds, then check again.

### Confirm with ARP (optional)

```bash
arp -a | grep 192.168.0
```

If the switch is at its default IP and your interface is on the right subnet, this shows which `enX` the switch is visible on.

---

## 3. Set a Static IP on the Switch's Subnet

**Why this is needed:** Your Mac is likely on 192.168.1.x or 10.0.0.x. The switch defaults to 192.168.0.1. Different subnets can't communicate without a router, so you need to temporarily put your Mac on 192.168.0.x.

### Method 1 — networksetup (when service name maps to the correct interface)

```bash
networksetup -setmanual "USB 10/100/1000 LAN" 192.168.0.100 255.255.255.0 192.168.0.1
```

Replace `USB 10/100/1000 LAN` with your actual service name from step 2.

### Method 2 — ifconfig (when the interface is dynamically created)

Use this when the interface doesn't appear in `networksetup -listallhardwareports`, or when Method 1 applies the IP to the wrong interface.

```bash
sudo ifconfig en8 192.168.0.100 netmask 255.255.255.0 up
```

Replace `en8` with whichever interface showed `status: active` in step 2.

### Verify the IP was assigned to the correct interface

```bash
ifconfig en8 | grep inet
```

Expected output:

```
inet 192.168.0.100 netmask 0xffffff00 broadcast 192.168.0.255
```

If the IP shows up on a different `enX` than the one connected to the switch, you'll get `(incomplete)` ARP entries and pings will fail. Use Method 2 on the correct interface.

---

## 4. Test Connectivity

```bash
ping 192.168.0.1
```

You should get replies. If ping fails, work through this diagnostic ladder:

1. **Check link light** — is the LED lit on the switch port where your cable is plugged in?
2. **Check ARP** — `arp -a | grep 192.168.0.1`
   - `(incomplete)` on a different `enX` → IP is set on the wrong interface (go back to step 3, use Method 2)
   - `(incomplete)` on the correct `enX` → switch may need a factory reset (see step 5)
   - No entry at all → cable or hub issue, try a different port or cable
3. **Subnet scan** — `nmap -sn 192.168.0.0/24` (if nmap is installed)
4. **Packet capture** — `sudo tcpdump -i en8 -n arp` to see if ARP requests/replies are flowing

---

## 5. Factory Reset

**When to do this:** The switch was previously configured, is in Omada controller mode, or doesn't respond at 192.168.0.1.

1. Locate the **reset pinhole** on the front panel
2. With the switch powered on, press and hold the reset button for **8–10 seconds**
3. All LEDs flash once — this confirms the reset was successful
4. Wait **60 seconds** for the switch to fully reboot

After reset, defaults are restored:

| Setting | Default |
|---------|---------|
| IP address | 192.168.0.1 |
| Username | admin |
| Password | admin |
| Mode | Standalone |

---

## 6. Access the Switch Web UI

1. Open `http://192.168.0.1` in your browser
2. Login: `admin` / `admin` (both lowercase)
3. On first login you'll be prompted to change the password

### Key menu locations (standalone mode, new GUI)

| Task | Menu Path |
|------|-----------|
| Create VLANs | L2 Features → VLAN → 802.1Q VLAN → VLAN Config |
| Set port PVID | L2 Features → VLAN → 802.1Q VLAN → Port Config |
| Management VLAN & IP | L3 Features → Interface |
| View port status | MONITORING → Port Statistics |

> **Standalone vs Controller mode:** If you switch from standalone to Omada controller mode, all standalone configuration is lost. Only switch modes intentionally.

---

## 7. Configure for Homelab (Quick Reference)

These steps configure the switch for the homelab VLAN (VLAN 10, 10.0.0.0/24). For detailed explanations, see [opnsense-vlan-setup.md](./opnsense-vlan-setup.md).

### 1. Create VLAN 10

**Menu:** L2 Features → VLAN → 802.1Q VLAN → VLAN Config

- VLAN ID: `10`
- VLAN Name: `homelab-lan`

See [Step A4](./opnsense-vlan-setup.md#step-a4--sg2008-create-vlan-10) for details.

### 2. Set port membership

**Menu:** L2 Features → VLAN → 802.1Q VLAN → VLAN Config → select VLAN 10

| Configuration | Ports 1–7 | Port 8 (uplink) |
|---------------|-----------|------------------|
| **Option A** (no trunk, recommended) | Untagged | Untagged |
| **Option B** (trunk, multi-VLAN ready) | Untagged | Tagged |

See [Step A5](./opnsense-vlan-setup.md#step-a5--sg2008-configure-port-membership) (Option A) or [Step B5](./opnsense-vlan-setup.md#step-b5--sg2008-configure-tagged-uplink) (Option B).

### 3. Set PVID on all ports

**Menu:** L2 Features → VLAN → 802.1Q VLAN → Port Config

Set PVID = `10` on all 8 ports.

See [Step A5](./opnsense-vlan-setup.md#step-a5--sg2008-configure-port-membership) for details.

### 4. Change management IP to homelab subnet

**Menu:** L3 Features → Interface

1. Click **Edit IPv4** on the VLAN 10 row (create a VLAN 10 interface first if it doesn't exist)
2. Set **IP Address Mode** to **Static**
3. Enter **IP Address**: `10.0.0.2`
4. Enter **Subnet Mask**: `255.255.255.0`
5. Click **Apply**, then **Save**

> **Note:** The TL-SG2008 V3 / newer firmware does not have the `SYSTEM → System IP` menu. Management IP is configured by assigning an IP to a VLAN interface under L3 Features → Interface. There is no explicit gateway field here — the management VLAN is implicitly whichever VLAN interface you assign an IP to. See [TP-Link FAQ 2122](https://www.tp-link.com/us/support/faq/2122/) and [TP-Link community post](https://community.tp-link.com/en/business/forum/topic/595460) for details.

See [Step A6](./opnsense-vlan-setup.md#step-a6--sg2008-set-management-vlan-and-ip) for details.

> **Warning:** After changing the management IP, you will lose access via 192.168.0.1. The switch will be reachable at 10.0.0.2 from the homelab network.

---

## 8. Clean Up Mac Network Settings

After you're done configuring the switch, restore your Mac's network to its normal state.

### If you used Method 1 (networksetup)

```bash
networksetup -setdhcp "USB 10/100/1000 LAN"
```

### If you used Method 2 (ifconfig)

```bash
sudo ifconfig en8 delete
```

Replace the service name or interface name with what you used in step 3.

---

## 9. Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---------|-------|-----|
| `networksetup -setmanual "Ethernet" ...` fails | "Ethernet" isn't a valid service name on your Mac | Run `networksetup -listallnetworkservices` to find the actual name (e.g., `USB 10/100/1000 LAN`) |
| USB-C hub interface not in `listallhardwareports` | Dynamically created interfaces don't always register with `networksetup` | Use `ifconfig \| grep -E "^en\|status:"` to find the active interface, then use Method 2 (`ifconfig`) |
| `ping 192.168.0.1` → no reply, `arp -a` shows `(incomplete)` on wrong `enX` | Static IP was applied to a different interface than the one connected to the switch | Use `sudo ifconfig <correct-enX> 192.168.0.100 netmask 255.255.255.0 up` |
| `ping 192.168.0.1` → no reply, `arp -a` shows `(incomplete)` on correct `enX` | Switch is not at default IP (was previously configured or in controller mode) | Factory reset: hold reset pinhole 8–10 seconds, wait 60 seconds |
| No `enX` interface shows `status: active` | USB-C hub not recognized or cable not connected | Unplug and replug the USB-C hub; try a different cable or switch port |
| Browser can't load `http://192.168.0.1` but ping works | Browser using proxy or HTTPS | Try incognito mode, ensure `http://` not `https://`, disable proxy for 192.168.0.x |
| Lost access after changing management VLAN/IP | Management IP moved to 10.0.0.2 on VLAN 10 | Access from a device on 10.0.0.0/24, or factory reset to restore defaults |

---

## 10. References

- [TP-Link TL-SG2008 product page](https://www.omadanetworks.com/us/service-provider/smart-switch/tl-sg2008/)
- [TP-Link 802.1Q VLAN config (new GUI)](https://www.tp-link.com/us/support/faq/2149/)
- [TP-Link Management VLAN config](https://www.tp-link.com/us/support/faq/3629/)
- [TP-Link factory reset for JetStream switches](https://www.tp-link.com/us/support/faq/379/)
- [TP-Link: How to change switch IP (new GUI)](https://www.tp-link.com/us/support/faq/2122/)
- [TP-Link Community: TL-SG2008P management VLAN](https://community.tp-link.com/en/business/forum/topic/595460)
- [OPNsense VLAN setup guide (this repo)](./opnsense-vlan-setup.md)
- Apple `networksetup` man page: `man networksetup`
