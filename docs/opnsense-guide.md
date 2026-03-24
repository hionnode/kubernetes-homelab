# OPNsense Guide

Comprehensive OPNsense reference for a Kubernetes homelab — covering configuration, troubleshooting, VM failures, network outages, service breakdowns, and recovery procedures.

**Applies to:** OPNsense 25.x on Proxmox VE 8.x, VM ID 101

**Related docs:**
- [opnsense-configuration-guide.md](opnsense-configuration-guide.md) — correct config values to validate against
- [opnsense-vlan-setup.md](opnsense-vlan-setup.md) — VLAN lockout recovery
- [opnsense-adblock-guide.md](opnsense-adblock-guide.md) — DNS blocklist issues
- [architecture-diagrams.md](architecture-diagrams.md) — network topology
- [talos-management-handbook.md](talos-management-handbook.md) — Kubernetes-side diagnostics

---

## Table of Contents

1. [Quick Reference Card](#1-quick-reference-card)
2. [Understanding the Failure Domains](#2-understanding-the-failure-domains)
3. [Systematic Triage](#3-systematic-triage)
4. [Establishing Access When Nothing Works](#4-establishing-access-when-nothing-works)
5. [VM-Level Failures](#5-vm-level-failures)
6. [Interface & Link Failures](#6-interface--link-failures)
7. [DHCP Failures](#7-dhcp-failures)
   - [7.6 Kea DHCP Reservation Not Registering Device](#76-kea-dhcp-reservation-not-registering-device)
   - [7.7 Kea DHCP vs ISC DHCP Reference](#77-kea-dhcp-vs-isc-dhcp-reference-opnsense-25-migration)
8. [DNS Resolution Failures](#8-dns-resolution-failures)
   - [8.6 Unbound DNS Not Running Despite Correct Configuration](#86-unbound-dns-not-running-despite-correct-configuration)
9. [NAT & Routing Failures](#9-nat--routing-failures)
10. [Firewall Rule Issues](#10-firewall-rule-issues)
11. [WebGUI Access Issues](#11-webgui-access-issues)
12. [API Troubleshooting](#12-api-troubleshooting)
13. [Post-Update Breakage](#13-post-update-breakage)
14. [Configuration Corruption & Recovery](#14-configuration-corruption--recovery)
15. [Performance Degradation](#15-performance-degradation)
16. [VLAN-Related Lockouts](#16-vlan-related-lockouts)
17. [Kubernetes-Specific OPNsense Issues](#17-kubernetes-specific-opnsense-issues)
- [Appendix A: Command Reference (Linux vs macOS)](#appendix-a-command-reference-linux-vs-macos)
- [Appendix B: OPNsense Console Menu Reference](#appendix-b-opnsense-console-menu-reference)
- [Appendix C: Proxmox qm Command Reference for VM 101](#appendix-c-proxmox-qm-command-reference-for-vm-101)

---

## 1. Quick Reference Card

### 1.1 Access Methods

| Method | Address | Prerequisites |
|--------|---------|---------------|
| WebGUI (WAN) | `https://<WAN-IP>` | WAN access rule enabled, on 192.168.1.x network |
| WebGUI (LAN) | `https://10.0.0.1` | On 10.0.0.x network, LAN interface up |
| SSH | `ssh root@10.0.0.1` | SSH enabled in System → Settings → Administration |
| Proxmox noVNC | `https://192.168.1.110:8006` → VM 101 → Console | Proxmox host reachable, no OPNsense network needed |
| API | `https://10.0.0.1/api/` | API key+secret generated, HTTPS reachable |

### 1.2 IP Address Map

```
┌─────────────────────────────────────────────────────────────┐
│  WAN (192.168.1.0/24)                                       │
│                                                             │
│  192.168.1.1       Main router / ISP gateway                │
│  192.168.1.110     Proxmox host management                  │
│  192.168.1.x       OPNsense WAN (DHCP from main router)    │
├─────────────────────────────────────────────────────────────┤
│  LAN (10.0.0.0/24)                                          │
│                                                             │
│  10.0.0.1          OPNsense LAN (gateway, DHCP, DNS)       │
│  10.0.0.2          TP-Link managed switch                   │
│  10.0.0.5          K8s API VIP (floating)                   │
│  10.0.0.10         talos-cp-1 (Proxmox VM, ID 200)         │
│  10.0.0.11         talos-cp-2 (physical)                    │
│  10.0.0.12         talos-cp-3 (physical)                    │
│  10.0.0.20         talos-worker-1 (physical)                │
│  10.0.0.21         talos-worker-2 (physical)                │
│  10.0.0.22         talos-worker-3 (physical)                │
│  10.0.0.50-99      MetalLB LoadBalancer pool                │
│  10.0.0.100-200    DHCP dynamic pool                        │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Key Ports & Default Credentials

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| WebGUI | 443 | HTTPS | Self-signed TLS cert |
| SSH | 22 | TCP | Must be enabled in admin settings |
| DNS (Unbound) | 53 | TCP/UDP | Listens on LAN + localhost |
| DHCP | 67/68 | UDP | Server on 67, client on 68 |
| API | 443 | HTTPS | Path prefix `/api/` |

**Default credentials:** `root` / `opnsense` (change immediately after install)

### 1.4 Emergency Commands Cheat Sheet

**From Proxmox host (SSH to 192.168.1.110):**

```bash
qm status 101                    # Is the VM running?
qm start 101                     # Start the VM
qm stop 101 && qm start 101     # Hard restart
qm monitor 101                   # Enter QEMU monitor
```

**From OPNsense console (via Proxmox noVNC):**

```bash
pfctl -d                          # Disable firewall (emergency access)
pfctl -e                          # Re-enable firewall
configctl kea restart             # Restart DHCP (Kea)
service unbound restart           # Restart DNS
configctl interface reconfigure   # Reconfigure all interfaces
```

**From your workstation:**

```bash
# Linux
ip addr show                      # Show interfaces and IPs
ip route show                     # Show routing table

# macOS
ifconfig                          # Show interfaces and IPs
netstat -rn                       # Show routing table

# Either
ping 10.0.0.1                    # Test LAN gateway
dig @10.0.0.1 google.com         # Test DNS resolution
curl -k https://10.0.0.1         # Test WebGUI reachability
```

---

## 2. Understanding the Failure Domains

### 2.1 Dependency Chain

When OPNsense goes down, it takes the entire Kubernetes network with it. Understanding the dependency chain is critical for efficient troubleshooting:

```
┌──────────────────────┐
│   Proxmox Host       │  Layer 0: Physical hardware + hypervisor
│   (192.168.1.110)    │  If this is down, everything is down
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   vmbr0 / vmbr1      │  Layer 1: Proxmox network bridges
│   (Bridge devices)   │  Connect physical NICs to VMs
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   OPNsense VM 101    │  Layer 2: Virtual machine
│   (QEMU/KVM)        │  If crashed/stopped, no network services
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   vtnet0 / vtnet1    │  Layer 3: VM network interfaces
│   (virtio NICs)      │  Must be up and correctly assigned
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   DHCP / DNS / NAT   │  Layer 4: Network services
│   Firewall / Routing │  Individual services can fail independently
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   K8s Nodes          │  Layer 5: Downstream clients
│   Workstations       │  Talos nodes, MetalLB, your laptop
│   Other devices      │
└──────────────────────┘
```

### 2.2 Failure Domain Matrix

| Component | Failure Mode | What Still Works | What Breaks |
|-----------|-------------|-----------------|-------------|
| Proxmox host | Power off / crash | Nothing on LAN | Everything — all VMs, all services |
| vmbr0 (WAN bridge) | Link down | LAN DHCP, DNS cache, inter-LAN traffic | Internet access, WAN WebGUI |
| vmbr1 (LAN bridge) | Link down | WAN connectivity from OPNsense itself | All LAN clients lose gateway, DHCP, DNS |
| OPNsense VM | Crashed / stopped | Proxmox host still reachable on WAN | All LAN services: DHCP, DNS, NAT, firewall |
| vtnet0 (WAN) | Interface down | LAN-to-LAN, DHCP, DNS (cached) | Internet from LAN, WAN WebGUI |
| vtnet1 (LAN) | Interface down | OPNsense WAN, Proxmox WAN | All LAN clients, K8s cluster |
| DHCP service | Stopped | Devices with existing leases (until expiry) | New devices, lease renewals |
| DNS (Unbound) | Stopped | IP-based connectivity, DHCP | All name resolution from LAN |
| NAT | Rules missing | LAN-to-LAN, DNS (if not forwarding) | LAN-to-internet |
| Firewall | Misconfigured | Depends on which rules are wrong | Blocked legitimate traffic |

### 2.3 Where Are You Connecting From?

Your troubleshooting approach depends on which network segment you are on:

```
Where are you right now?
        │
        ├── On the LAN (10.0.0.x)?
        │       │
        │       ├── Can ping 10.0.0.1? ──→ OPNsense is reachable, problem is service-level
        │       │                           Go to Sections 7-12
        │       │
        │       └── Cannot ping 10.0.0.1? ──→ Interface or VM problem
        │                                     Go to Section 4.1 (Proxmox console)
        │
        ├── On the WAN (192.168.1.x)?
        │       │
        │       ├── Can reach Proxmox (192.168.1.110:8006)?
        │       │       │
        │       │       ├── Yes ──→ Use noVNC console for OPNsense
        │       │       │           Go to Section 4.1
        │       │       │
        │       │       └── No ──→ Proxmox host issue, not OPNsense
        │       │
        │       └── Can reach OPNsense WAN IP?
        │               │
        │               ├── Yes ──→ WAN side works, LAN side broken
        │               │           Go to Section 6.3
        │               │
        │               └── No ──→ VM may be down
        │                          Go to Section 4.1
        │
        └── No network at all?
                │
                └── Physical access to Proxmox host?
                        │
                        ├── Yes ──→ Connect monitor+keyboard, or use
                        │           IPMI/iDRAC if available
                        │
                        └── No ──→ Cannot troubleshoot remotely
                                   Need physical access
```

---

## 3. Systematic Triage

### 3.1 Five-Layer Check

Work bottom-up. Do not skip layers — a Layer 2 failure masquerades as a Layer 4 failure.

**Layer 1: Is the VM running?**

```bash
# From Proxmox host
qm status 101
# Expected: status: running
```

If not running → [Section 5.1](#51-vm-crashed--stopped)

**Layer 2: Are the interfaces up?**

```bash
# From OPNsense console (Proxmox noVNC)
ifconfig vtnet0
ifconfig vtnet1
# Look for: flags=<UP,BROADCAST,RUNNING> and valid inet addresses
```

If interfaces are down → [Section 6](#6-interface--link-failures)

**Layer 3: Is L3 reachable?**

```bash
# From your workstation
ping 10.0.0.1          # LAN gateway
ping 192.168.1.1       # Main router (from OPNsense console)
```

If not reachable → [Section 6](#6-interface--link-failures) or [Section 4](#4-establishing-access-when-nothing-works)

**Layer 4: Are services responding?**

```bash
# From your workstation
dig @10.0.0.1 google.com     # DNS
curl -k https://10.0.0.1     # WebGUI / web server
# From OPNsense console
pluginctl -s dhcpd            # DHCP status
service unbound status        # DNS status
```

If services are down → [Section 7](#7-dhcp-failures), [Section 8](#8-dns-resolution-failures), or [Section 11](#11-webgui-access-issues)

**Layer 5: Is traffic flowing?**

```bash
# From a LAN client
ping 8.8.8.8            # Internet reachability (bypasses DNS)
curl https://example.com # Full stack: DNS + NAT + routing
```

If traffic is blocked → [Section 9](#9-nat--routing-failures) or [Section 10](#10-firewall-rule-issues)

### 3.2 Master Decision Tree

Start here when something breaks. Follow the arrows.

```
                              ┌───────────────────────────┐
                              │   Can you ping 10.0.0.1?  │
                              └─────────────┬─────────────┘
                                   ┌────────┴────────┐
                                  YES                NO
                                   │                  │
                                   ▼                  ▼
                    ┌──────────────────────┐   ┌──────────────────────┐
                    │ Can you resolve DNS? │   │ Can you reach Proxmox│
                    │ dig @10.0.0.1 test   │   │ 192.168.1.110:8006?  │
                    └──────────┬───────────┘   └──────────┬───────────┘
                       ┌───────┴───────┐          ┌───────┴───────┐
                      YES             NO         YES             NO
                       │               │           │               │
                       ▼               ▼           ▼               ▼
            ┌──────────────┐  ┌──────────────┐  ┌──────────┐  ┌──────────┐
            │ Can you reach│  │  Section 8   │  │ Check VM │  │ Proxmox  │
            │ the internet?│  │  DNS Failure │  │ status   │  │ host is  │
            └──────┬───────┘  └──────────────┘  │ via      │  │ down or  │
              ┌────┴────┐                       │ noVNC    │  │ network  │
             YES       NO                       │ console  │  │ issue    │
              │         │                       └────┬─────┘  └──────────┘
              ▼         ▼                       ┌────┴────┐
     ┌────────────┐  ┌──────────────┐         YES       NO
     │  Specific  │  │ Section 9    │           │         │
     │  service   │  │ NAT/Routing  │           ▼         ▼
     │  issue?    │  │ Failure      │   ┌──────────┐  ┌──────────┐
     │ Sections   │  └──────────────┘   │ Section 6│  │ Section 5│
     │ 10-12      │                     │ Interface│  │ VM-level │
     └────────────┘                     │ Failure  │  │ Failure  │
                                        └──────────┘  └──────────┘
```

### 3.3 Gathering Diagnostic Data

> [!IMPORTANT]
> Collect diagnostics **before** making changes. If you change things first, you lose visibility into the root cause.

**From OPNsense console or SSH:**

```bash
# System info
opnsense-version                          # Firmware version
uptime                                     # How long since last boot
dmesg | tail -50                          # Recent kernel messages

# Network state
ifconfig -a                                # All interface status
netstat -rn                                # Routing table
pfctl -s info                             # Firewall state summary
pfctl -s nat                              # NAT rules
pfctl -s rules                            # Active firewall rules

# Service state
pluginctl -s dhcpd                         # DHCP service status
service unbound status                     # DNS status
sockstat -4 -l                            # Listening ports

# Logs
cat /var/log/system/latest.log | tail -50  # System log (OPNsense 25)
cat /var/log/filter/latest.log | tail -50  # Firewall log (OPNsense 25)
cat /tmp/dhcpd.leases                      # Current DHCP leases
```

**From Proxmox host:**

```bash
qm status 101                              # VM status
qm config 101                              # VM configuration
cat /var/log/pve/tasks/active              # Active Proxmox tasks
journalctl -u pve-guests --since "1 hour ago"  # Recent VM events
ip link show vmbr0                         # WAN bridge status
ip link show vmbr1                         # LAN bridge status
```

---

## 4. Establishing Access When Nothing Works

> [!TIP]
> This is the "break glass" section. When you cannot reach OPNsense through normal means, start here.

### 4.1 Proxmox Console Access (No Network Required)

The Proxmox noVNC console gives you direct access to the OPNsense VM regardless of any network issue. This is your primary recovery path.

**Step 1: Access Proxmox WebGUI**

Open `https://192.168.1.110:8006` in your browser. You need to be on the 192.168.1.x network:
- Connect via WiFi to your main router, or
- Plug directly into the WAN-side network

**Step 2: Open VM Console**

1. Navigate to **Datacenter → Node → VM 101 (opnsense)**
2. Click **Console** in the top-right (or use the Console tab)
3. The OPNsense console menu appears

**Step 3: Verify VM state**

If the console shows a login prompt or the OPNsense menu, the VM is running. If it's blank or shows BIOS/boot output, the VM may be starting or stuck.

Login with `root` and your password to access the console menu (see [Appendix B](#appendix-b-opnsense-console-menu-reference)).

### 4.2 Manually Assigning a Static IP on Your Workstation

When DHCP is down, your workstation won't get an IP address on the LAN. Assign one manually to establish connectivity.

> [!WARNING]
> Remember to revert these changes after troubleshooting, or you'll have a static IP that may conflict later.

**Linux:**

```bash
# Find your LAN-facing interface
ip link show
# Look for the interface connected to the homelab switch (e.g., eth0, enp3s0)

# Assign a static IP in the DHCP range (pick one unlikely to conflict)
sudo ip addr add 10.0.0.199/24 dev eth0

# Add a route to the LAN gateway
sudo ip route add default via 10.0.0.1 dev eth0

# Test connectivity
ping 10.0.0.1

# --- CLEANUP (after troubleshooting) ---
sudo ip addr del 10.0.0.199/24 dev eth0
# Then restart NetworkManager or dhclient to get a DHCP lease
sudo systemctl restart NetworkManager
```

**macOS:**

```bash
# Find your LAN-facing interface (usually en0 for Ethernet)
networksetup -listallhardwareports

# Assign static IP
sudo networksetup -setmanual "Ethernet" 10.0.0.199 255.255.255.0 10.0.0.1

# Test connectivity
ping 10.0.0.1

# --- CLEANUP (after troubleshooting) ---
sudo networksetup -setdhcp "Ethernet"
```

> [!NOTE]
> On macOS, the interface name in `networksetup` is the "Hardware Port" name (e.g., "Ethernet", "USB 10/100/1000 LAN"), not the BSD device name (e.g., `en0`).

### 4.3 Reaching OPNsense from the WAN Side

If you are on the 192.168.1.x network (e.g., WiFi to your main router), you can access OPNsense via its WAN IP — but only if WAN access is enabled.

**Find the WAN IP:**

```bash
# Check DHCP leases on your main router, or:
# From Proxmox noVNC console → OPNsense menu → Option 7 (Ping host)
# Or just check ifconfig vtnet0 from the console
```

**If WebGUI is not reachable on WAN:**

The WebGUI listens on all interfaces by default, but the firewall blocks WAN access unless you have an explicit rule. From the OPNsense console:

```bash
# Temporarily disable the firewall to allow WAN WebGUI access
pfctl -d

# Access https://<WAN-IP> from your browser
# Re-enable firewall immediately after making changes
pfctl -e
```

> [!CAUTION]
> Disabling the firewall exposes all services to the WAN network. Re-enable it as soon as you are done. This is safe on a double-NAT homelab (behind your main router) but do not do this if your WAN is a public IP.

### 4.4 Emergency: VM Not Running

```bash
# From Proxmox host (SSH to 192.168.1.110)
qm status 101
```

If the status is `stopped`:

```bash
# Start the VM
qm start 101

# Watch the console via noVNC to verify it boots
# Wait 30-60 seconds for OPNsense to fully start
```

If `qm start` fails, see [Section 5.3](#53-vm-wont-start).

---

## 5. VM-Level Failures

### 5.1 VM Crashed / Stopped

**Symptoms:**
- No response on any OPNsense IP (10.0.0.1, WAN IP)
- All LAN clients lose DHCP, DNS, internet
- Proxmox shows VM 101 as "stopped"

**Triage:**

```bash
# From Proxmox host
qm status 101
# If "stopped", check why it stopped:

# Check for OOM kill
dmesg | grep -i "out of memory"
dmesg | grep -i "killed process"

# Check Proxmox task log for errors
cat /var/log/pve/tasks/active
journalctl -u pve-guests --since "1 hour ago" | grep 101
```

**Fix:**

```bash
# Start the VM
qm start 101

# Verify it is running
qm status 101

# Watch boot via noVNC to ensure clean startup
```

**If it keeps crashing (OOM):**

```bash
# Check current memory allocation
qm config 101 | grep memory

# Increase memory if needed (VM must be stopped)
qm set 101 -memory 8192
qm start 101
```

**Verify recovery:**

```bash
# From your workstation
ping 10.0.0.1
dig @10.0.0.1 google.com
```

### 5.2 Boot Loop / Kernel Panic

**Symptoms:**
- noVNC console shows repeated boot messages or panic text
- VM status shows "running" but OPNsense never reaches login prompt

**Triage via Proxmox console (noVNC):**

Watch the boot output. Common patterns:

| Console Output | Likely Cause | Action |
|---------------|-------------|--------|
| `Kernel panic` | Corrupted kernel or filesystem | Boot recovery ISO |
| `Mounting from ufs:/dev/vtbd0p2 failed` | Disk corruption | Run fsck |
| `Repeating boot logo` | Boot loop after bad update | Rollback snapshot |
| No output at all | VM hardware config issue | Check qm config |

**Fix — fsck from single-user mode:**

1. From Proxmox noVNC, watch boot
2. When the FreeBSD boot menu appears, select **Single User Mode** (option 2)
3. At the `#` prompt:

```bash
fsck -y /
mount -a
exit    # Continue to multi-user
```

**Fix — rollback to Proxmox snapshot:**

```bash
# From Proxmox host
qm listsnapshot 101
# Find a known-good snapshot

qm rollback 101 --snapname <snapshot-name>
qm start 101
```

> [!CAUTION]
> Rolling back a snapshot reverts the entire VM state (disks and RAM if saved). Any config changes made after the snapshot will be lost.

### 5.3 VM Won't Start

**Common errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `not enough memory` | Host RAM exhausted | Stop other VMs or reduce VM memory |
| `drive mirror is locked` | Disk locked by another process | `qm unlock 101` |
| `TASK ERROR: can't lock file` | Stale lock file | Check for running processes: `ps aux \| grep 101` |
| `ISO not found` | Referenced ISO removed | Remove CD-ROM: `qm set 101 -delete ide2` |
| `bridge vmbr1 does not exist` | Bridge config issue | Check `/etc/network/interfaces` on Proxmox |

```bash
# Check current VM config for obvious issues
qm config 101

# Try starting with verbose output
qm start 101 --debug

# If locked
qm unlock 101
qm start 101
```

### 5.4 QEMU Guest Agent Issues

The QEMU Guest Agent provides Proxmox with information about the VM's internal state (IP addresses, filesystem freeze for snapshots). OPNsense runs on FreeBSD, which requires the FreeBSD-specific agent.

**Check if guest agent is enabled in Proxmox:**

```bash
qm config 101 | grep agent
# Expected: agent: 1
```

**Install/enable inside OPNsense (via console or SSH):**

```bash
# Install the guest agent package
pkg install qemu-guest-agent

# Enable on boot
sysrc qemu_guest_agent_enable="YES"

# Start now
service qemu-guest-agent start
```

---

## 6. Interface & Link Failures

The path from physical cable to OPNsense virtual NIC has multiple potential failure points:

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Physical    │    │   Proxmox    │    │  Tap Device  │    │  OPNsense    │
│  NIC         │───▶│   Bridge     │───▶│  (auto)      │───▶│  virtio NIC  │
│              │    │              │    │              │    │              │
│  enp2s0      │    │  vmbr0       │    │  tap101i0    │    │  vtnet0 (WAN)│
│  enx1c86...  │    │  vmbr1       │    │  tap101i1    │    │  vtnet1 (LAN)│
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
       ▲                   ▲                   ▲                   ▲
   Check 1             Check 2            Check 3             Check 4
   Cable/link          Bridge up?         Device exists?      UP flag set?
```

### 6.1 Verifying Proxmox Bridge Status

**From Proxmox host:**

```bash
# Check bridge status
ip link show vmbr0
ip link show vmbr1
# Both should show: state UP

# Check which physical interfaces are in each bridge
bridge link show
# Expected:
#   enp2s0 → vmbr0
#   enx1c860b363f63 → vmbr1

# Check tap devices exist (created when VM is running)
ip link show | grep tap101
# Expected: tap101i0 and tap101i1

# Verify bridge configuration
cat /etc/network/interfaces
```

**Expected `/etc/network/interfaces` (relevant sections):**

```
auto vmbr0
iface vmbr0 inet static
    address 192.168.1.110/24
    gateway 192.168.1.1
    bridge-ports enp2s0
    bridge-stp off
    bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
    bridge-ports enx1c860b363f63
    bridge-stp off
    bridge-fd 0
```

### 6.2 WAN Interface Down (vtnet0)

**Symptoms:**
- LAN still works (DHCP, DNS cache hits, LAN-to-LAN)
- No internet access from LAN clients
- `ping 8.8.8.8` fails from LAN clients
- OPNsense console: `ifconfig vtnet0` shows no inet address or `<DOWN>`

**Triage:**

```bash
# From OPNsense console
ifconfig vtnet0
# Check for: flags=<UP,BROADCAST,RUNNING> and inet 192.168.1.x

# If no IP, try renewing DHCP
dhclient vtnet0

# If interface is DOWN
ifconfig vtnet0 up
```

**From Proxmox host:**

```bash
# Check physical WAN link
ip link show enp2s0
# Look for: state UP

# Check bridge
ip link show vmbr0
bridge link show | grep enp2s0

# Check cable (carrier detection)
cat /sys/class/net/enp2s0/carrier
# 1 = cable connected, 0 = no link
```

**Fixes:**

1. **No DHCP lease:** Main router may have changed. Try `dhclient vtnet0` on OPNsense console. Check main router DHCP pool.
2. **Physical link down:** Check/replace Ethernet cable to WAN port. Verify port on main router is active.
3. **Bridge misconfigured:** Compare `/etc/network/interfaces` with expected config above. Restart networking: `ifreload -a` on Proxmox.

### 6.3 LAN Interface Down (vtnet1)

**Symptoms:**
- All LAN clients lose connectivity (DHCP, DNS, gateway)
- K8s cluster becomes unreachable
- OPNsense WAN still works (can ping internet from OPNsense console)
- `ifconfig vtnet1` on OPNsense shows no inet or `<DOWN>`

**Triage:**

```bash
# From OPNsense console
ifconfig vtnet1
# Expected: inet 10.0.0.1 netmask 0xffffff00 (255.255.255.0)

# If interface is DOWN
ifconfig vtnet1 up

# If IP is missing, reassign
ifconfig vtnet1 inet 10.0.0.1 netmask 255.255.255.0
```

**From Proxmox host:**

```bash
# Check physical LAN link
ip link show enx1c860b363f63
cat /sys/class/net/enx1c860b363f63/carrier

# Check bridge
ip link show vmbr1
bridge link show | grep enx1c860b363f63
```

**If the physical NIC name changed** (USB NICs can change names after reboot):

```bash
# List all network interfaces on Proxmox
ip link show

# Find the USB NIC by MAC address
ip link show | grep -B1 "1c:86:0b:36:3f:63"
# Update /etc/network/interfaces if the name changed
```

### 6.4 Both Interfaces Down

If both vtnet0 and vtnet1 are down simultaneously, the issue is almost certainly at the VM level, not the network level:

- VM is not running → [Section 5.1](#51-vm-crashed--stopped)
- VM boot failure → [Section 5.2](#52-boot-loop--kernel-panic)
- Interface assignments changed inside OPNsense → Use console menu option 1 (Assign interfaces)

### 6.5 Physical Cable / Switch Port Verification

**TP-Link switch management** (if reachable at 10.0.0.2):

```bash
# From a client with network access (or use static IP per Section 4.2)
# Access switch WebGUI
open http://10.0.0.2    # macOS
xdg-open http://10.0.0.2  # Linux
```

**Physical checks:**

1. **Link LEDs:** Check LEDs on the TP-Link switch for the Proxmox uplink port. Solid/blinking green = good. Off = no link.
2. **Cable swap:** Try a known-good cable.
3. **Port swap:** Move the cable to a different switch port.
4. **NIC LED:** Check the USB LAN adapter LED on the Proxmox host.

---

## 7. DHCP Failures

### 7.1 No Clients Getting Addresses

**Symptoms:**
- All clients show 169.254.x.x (APIPA) addresses
- `ip addr show` (Linux) or `ifconfig` (macOS) shows link-local only
- K8s nodes can't get their expected IPs

**Triage from OPNsense console:**

```bash
# Check if Kea DHCP service is running
configctl kea status
# If not running:
configctl kea start

# Alternatively
service kea status
service kea start

# Check Kea DHCP configuration (JSON format)
cat /usr/local/etc/kea/kea-dhcp4.conf
# Verify: subnet 10.0.0.0/24 with correct pool range

# Check for errors in logs
grep -i kea /var/log/kea/latest.log
```

**Common causes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Kea DHCP service not running | `configctl kea status` returns error | Start service, check why it stopped |
| DHCP not enabled on LAN | Config shows no LAN pool | WebGUI → Services → Kea DHCP → enable on LAN |
| LAN interface down | `ifconfig vtnet1` shows DOWN | Fix interface first ([Section 6.3](#63-lan-interface-down-vtnet1)) |
| Pool range invalid | Range doesn't match subnet | Fix to 10.0.0.100-200 per config guide |

**Force client DHCP renewal:**

```bash
# Linux
sudo dhclient -r eth0 && sudo dhclient eth0
# or
sudo systemctl restart NetworkManager

# macOS
sudo ipconfig set en0 DHCP
# or
sudo networksetup -setdhcp "Ethernet"
```

### 7.2 Some Clients Work, Others Don't

**Symptoms:**
- Existing devices retain connectivity
- New devices can't get addresses
- Some physical nodes get IPs, others don't

**Triage:**

```bash
# Check lease pool utilization (Kea uses CSV lease file)
cat /var/db/kea/kea-leases4.csv | wc -l
# Compare with pool size (10.0.0.100-200 = 101 addresses)

# Check for specific MAC in leases
grep "xx:xx:xx:xx:xx:xx" /var/db/kea/kea-leases4.csv
```

**Common causes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Pool exhausted | Lease count ≥ 101 | Reduce lease time or expand range |
| Switch port VLAN mismatch | Client on wrong VLAN | Check switch port config at 10.0.0.2 |
| Client NIC issue | Other clients on same switch port work | Test with different cable/port |

### 7.3 Wrong Addresses Assigned

**Symptoms:**
- Clients get IPs outside expected range
- Multiple devices fighting over same IP
- Clients get 192.168.x.x instead of 10.0.0.x

**Diagnosis:**

```bash
# Check for rogue DHCP server
# Linux:
sudo nmap --script broadcast-dhcp-discover -e eth0

# macOS:
sudo nmap --script broadcast-dhcp-discover -e en0
```

If a rogue DHCP server responds (another device on the LAN advertising DHCP), identify and disable it. Common culprits: consumer routers/APs plugged into the LAN in router mode instead of AP mode.

### 7.4 Reservations Not Working (Talos Nodes)

**Symptoms:**
- Talos nodes getting dynamic IPs instead of their reserved assignments
- Node appears in DHCP leases with wrong IP

**Cause:** The MAC address (hw-address) in the reservation doesn't match the node's actual MAC. This commonly happens after:
- VM recreation (talos-cp-1 on Proxmox gets a new MAC)
- Physical NIC replacement
- PXE boot vs OS boot using different NICs

**Fix:**

1. Find the actual MAC address:

```bash
# For Proxmox VM (talos-cp-1)
qm config 200 | grep net
# Look for: net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr1

# For physical nodes, check Kea DHCP leases on OPNsense
grep "10.0.0." /var/db/kea/kea-leases4.csv
```

2. Update the reservation in OPNsense WebGUI:
   - Services → Kea DHCP → Reservations
   - Edit the entry for the affected node
   - Update the MAC address (must be lowercase colon-separated: `aa:bb:cc:dd:ee:ff`)
   - Save → Apply

### 7.5 DHCP Diagnostics from Client

**Linux — verbose DHCP request:**

```bash
# Release current lease and request new one with verbose output
sudo dhclient -v -r eth0
sudo dhclient -v eth0

# Watch DHCP traffic
sudo tcpdump -i eth0 port 67 or port 68 -vv
```

**macOS — verbose DHCP request:**

```bash
# Renew DHCP lease
sudo ipconfig set en0 DHCP

# View DHCP information
ipconfig getpacket en0

# Watch DHCP traffic
sudo tcpdump -i en0 port 67 or port 68 -vv
```

### 7.6 Kea DHCP Reservation Not Registering Device

**Symptoms:**
- DHCP reservation configured for a device (e.g., TP-Link SG2008 switch at 10.0.0.2)
- Device does not receive the reserved IP address
- Device either gets a dynamic IP from the pool or no IP at all
- Reservation appears correct in WebGUI → Services → Kea DHCP → Reservations

**OPNsense 25-specific context:** OPNsense 25.1 replaced ISC DHCP with Kea DHCP. Kea uses JSON configuration and has different reservation matching behavior than ISC DHCP.

**Step-by-step diagnosis:**

**1. Verify Kea is actually running (not ISC DHCP)**

The ISC-to-Kea migration may not have completed properly after upgrade:

```bash
# Check Kea service status
configctl kea status

# Verify which process owns port 67
sockstat -4 -l | grep :67
# Expected: kea-dhcp4
# Bad: dhcpd (means ISC DHCP is still running)
```

If ISC DHCP is still running, navigate to Services → Kea DHCP in WebGUI and enable it, which disables ISC DHCP.

**2. Check Kea configuration file**

```bash
cat /usr/local/etc/kea/kea-dhcp4.conf
```

Look for a `reservations` array inside the subnet declaration. Example of a correct reservation:

```json
{
  "hw-address": "aa:bb:cc:dd:ee:ff",
  "ip-address": "10.0.0.2",
  "hostname": "tp-link-switch"
}
```

**3. Verify MAC address format (case sensitivity)**

Kea requires **lowercase, colon-separated hex** for MAC addresses:
- Correct: `aa:bb:cc:dd:ee:ff`
- Wrong: `AA:BB:CC:DD:EE:FF`, `aa-bb-cc-dd-ee-ff`, `aabb.ccdd.eeff`

> [!WARNING]
> **Real-world finding:** The OPNsense WebGUI may write **uppercase** MACs to the Kea config file. For example, a reservation entered via WebGUI can produce `"hw-address": "3C:64:CF:B2:49:9B"` in `/usr/local/etc/kea/kea-dhcp4.conf`. While Kea documentation claims case-insensitive matching, uppercase MACs combined with `match-client-id: true` and stale declined leases have been observed to prevent allocation entirely.

Verify the actual config:

```bash
# Check what MAC format is in the config
grep hw-address /usr/local/etc/kea/kea-dhcp4.conf
```

Find the device's actual MAC:

```bash
# From OPNsense console
arp -a | grep 10.0.0
```

If the MAC is uppercase in the config, edit it to lowercase or re-create the reservation.

**4. Check Kea lease database**

```bash
cat /var/db/kea/kea-leases4.csv
# Look for the device's MAC address
grep "aa:bb:cc:dd:ee:ff" /var/db/kea/kea-leases4.csv
```

If the MAC appears with a different IP, there may be a stale lease. Kea honors existing leases over new reservations until the lease expires.

**5. Check hw-address vs client-id mismatch**

Some managed switches send a DHCP client identifier (option 61) that differs from their MAC address. If the reservation uses `hw-address` but the device identifies via `client-id`, Kea won't match.

```bash
# Check Kea logs for the actual identifiers sent by the device
grep -i kea /var/log/kea/latest.log | grep -i "DHCPDISCOVER\|DHCPREQUEST" | tail -20
```

If you see a `client-id` that differs from the MAC, update the reservation to use `client-id` instead:

```json
{
  "client-id": "01:aa:bb:cc:dd:ee:ff",
  "ip-address": "10.0.0.2"
}
```

**6. Verify reserved IP is within the subnet scope**

The reserved IP (e.g., 10.0.0.2) must be within the configured subnet (10.0.0.0/24) but does **NOT** need to be within the dynamic pool range (10.0.0.100-200). Verify the subnet declaration in Kea config covers 10.0.0.0/24.

**7. Restart Kea and trigger a new DHCP request**

```bash
# Restart Kea and watch logs
configctl kea restart
# Then watch for the device's DHCP request
tail -f /var/log/kea/latest.log
```

Trigger a DHCP request from the device by rebooting it or disconnecting/reconnecting its uplink cable.

**8. Critical check: Is the device actually making DHCP requests?**

Some managed switches default to a **static IP** and won't make DHCP requests at all:
- **TP-Link SG2008** defaults to static IP `192.168.0.1`
- The switch must be set to DHCP mode in its own management interface first
- Access the switch management UI at its default IP, then change the IP configuration to DHCP

If the switch is using a static IP, no DHCP reservation will ever apply — the switch never sends a DHCPDISCOVER.

**9. Check for stale declined lease blocking reservation**

> [!IMPORTANT]
> This is the most common cause of Kea reservation failures on OPNsense 25. A "declined" lease in the database blocks ALL future allocations for that IP — including valid reservations.

When a DHCP client declines an offered address (e.g., because it detected an ARP conflict on the network), Kea marks the lease as "declined" with a default 24-hour hold (`decline-probation-period`: 86400s). If the lease database is corrupted or the declined state persists beyond the probation period, it permanently blocks the reserved IP.

**Log signature** (check with `grep -i kea /var/log/kea/latest.log | grep -i "CONFLICT\|ALLOC_FAIL"`):

```
ALLOC_ENGINE_V4_DISCOVER_ADDRESS_CONFLICT: conflicting reservation for address 10.0.0.2 with existing lease
ALLOC_ENGINE_V4_ALLOC_FAIL: failed to allocate an IPv4 address after 101 attempt(s)
ALLOC_ENGINE_V4_ALLOC_FAIL_SUBNET: failed to allocate an IPv4 lease in the subnet 10.0.0.0/24
```

**Diagnose — check the lease database for declined entries:**

```bash
# Check for declined leases (state=1 in CSV, column 10)
grep "10.0.0.2" /var/db/kea/kea-leases4.csv
# A declined lease will show state=1 with an empty hardware address
# CSV states: 0=active, 1=declined, 2=expired-reclaimed

# Or query via Kea control socket
echo '{"command": "lease4-get", "arguments": {"ip-address": "10.0.0.2"}}' | \
  socat UNIX:/var/run/kea/kea4-ctrl-socket -
```

**Fix — delete the stale declined lease:**

Option A — via Kea control socket (preferred, no restart needed):

```bash
echo '{"command": "lease4-del", "arguments": {"ip-address": "10.0.0.2"}}' | \
  socat UNIX:/var/run/kea/kea4-ctrl-socket -
```

Option B — via WebGUI: Services → Kea DHCP → Leases → find the 10.0.0.2 entry → delete it.

Option C — manual CSV edit (if control socket unavailable):

```bash
configctl kea stop
# Edit /var/db/kea/kea-leases4.csv — remove the line containing 10.0.0.2 with state=1 (declined)
vi /var/db/kea/kea-leases4.csv
configctl kea start
```

After clearing the lease, trigger a new DHCP request from the device (power cycle or reconnect uplink), then verify:

```bash
tail -f /var/log/kea/latest.log
# Should now show: DHCP4_LEASE_ALLOC ... 10.0.0.2 for the device
```

**Prevention — reduce the decline probation period:**

Edit `/usr/local/etc/kea/kea-dhcp4.conf` (or via WebGUI advanced settings) and add at the top level:

```json
"decline-probation-period": 60
```

This reduces the hold time for declined addresses from 24 hours (86400s) to 60 seconds. In homelabs with managed switches that aggressively decline IPs, a short probation period prevents address pool exhaustion.

**Diagnostic summary:**

| Check | Command | Expected | If Wrong |
|-------|---------|----------|----------|
| Kea running | `sockstat -4 -l \| grep :67` | `kea-dhcp4` | Enable Kea in WebGUI |
| Config correct | `cat /usr/local/etc/kea/kea-dhcp4.conf` | Reservation present | Add reservation via WebGUI |
| MAC format | Check reservation entry | Lowercase colon-separated | Fix MAC format |
| Lease conflict | `grep MAC /var/db/kea/kea-leases4.csv` | No conflicting lease | Wait for expiry or clear leases |
| **Declined lease** | `grep "10.0.0.2" /var/db/kea/kea-leases4.csv` | No state=1 entry | Delete via control socket or CSV edit |
| client-id match | Check Kea logs for identifiers | hw-address matches | Switch to client-id reservation |
| Device requests DHCP | `tail -f /var/log/kea/latest.log` | DHCPDISCOVER seen | Set device to DHCP mode |

**Special case — managed switch declining every IP (DHCPDECLINE loop):**

If you see `ALLOC_ENGINE_V4_DISCOVER_ADDRESS_CONFLICT` followed by `DHCP4_DECLINE_LEASE` for every offered IP, the device is doing DAD (Duplicate Address Detection) ARP probes and detecting phantom conflicts. This is common with managed switches (e.g., TP-Link SG2008) that bridge WAN and LAN traffic — the switch sees stray ARP responses through its own switching fabric.

Signs of this problem:
- Lease file fills with pairs: one active lease (state=0) then one declined lease (state=1) for every IP
- The device cycles through the entire DHCP pool within minutes
- `tcpdump -i vtnet1 arp` on OPNsense shows WAN-side ARP traffic (192.168.1.x) on the LAN interface

Fix:
1. **Set a static IP on the managed switch** via its web UI — this is the recommended approach for network infrastructure devices
2. Set `decline-probation-period` to 60 in Kea config to prevent pool exhaustion while debugging
3. Investigate and fix L2 isolation between WAN and LAN bridges on the hypervisor

### 7.7 Kea DHCP vs ISC DHCP Reference (OPNsense 25 Migration)

OPNsense 25.1 replaced ISC DHCP with Kea DHCP. Use this table when following older guides or migrating configurations:

| Task | ISC DHCP (pre-25.1) | Kea DHCP (25.1+) |
|------|---------------------|-------------------|
| Service status | `service dhcpd status` | `configctl kea status` |
| Restart service | `pluginctl -s dhcpd` | `configctl kea restart` |
| Config file | `/var/dhcpd/etc/dhcpd.conf` | `/usr/local/etc/kea/kea-dhcp4.conf` |
| Config format | ISC conf syntax | JSON |
| Lease file | `/tmp/dhcpd.leases` | `/var/db/kea/kea-leases4.csv` |
| Lease format | Text blocks | CSV |
| WebGUI path | Services → DHCPv4 | Services → Kea DHCP |
| Static entries | "Static Mappings" | "Reservations" |
| Reservation match | MAC address only | `hw-address` or `client-id` |
| Log keyword | `dhcpd` | `kea` |

---

## 8. DNS Resolution Failures

### 8.1 Total DNS Failure

**Symptoms:**
- `dig @10.0.0.1 google.com` returns no response or connection refused
- `nslookup` fails on all queries
- Web browsers show "DNS_PROBE_FINISHED_NXDOMAIN" or similar
- Pinging by IP works fine (`ping 8.8.8.8` succeeds)

**Triage from OPNsense console:**

```bash
# Is Unbound running?
service unbound status

# If not running, start it
service unbound start

# Check what's listening on port 53
sockstat -4 -l | grep :53
# Expected: unbound ... *:53

# Check Unbound configuration
cat /var/unbound/unbound.conf | head -50

# Check for errors
grep -i unbound /var/log/system/latest.log
```

**Common causes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Unbound not running | `service unbound status` shows not running | `service unbound start` |
| Not listening on LAN | `sockstat` shows only 127.0.0.1:53 | WebGUI → Services → Unbound → Network Interfaces → add LAN |
| Config syntax error | Unbound won't start, check logs | `unbound-checkconf /var/unbound/unbound.conf` |
| Port conflict | Another service on port 53 | `sockstat -4 -l \| grep :53` to find the culprit |

### 8.2 Internal Works, External Fails

**Symptoms:**
- `dig @10.0.0.1 talos-cp-1.homelab.local` works
- `dig @10.0.0.1 google.com` fails or times out
- Host overrides resolve, but external domains don't

**This means Unbound is running but forwarding is broken.**

**Triage:**

```bash
# From OPNsense console, test upstream DNS directly
drill google.com @1.1.1.1
drill google.com @8.8.8.8

# If upstream DNS is unreachable, the problem is WAN/NAT, not DNS
# Test WAN connectivity
ping 1.1.1.1
ping 8.8.8.8
```

**If WAN works but forwarding doesn't:**

```bash
# Check forwarding configuration
cat /var/unbound/unbound.conf | grep -A5 forward-zone

# Expected:
# forward-zone:
#     name: "."
#     forward-addr: 1.1.1.1
#     forward-addr: 8.8.8.8
```

**Fix:** WebGUI → Services → Unbound DNS → General → ensure "DNS Query Forwarding" is enabled and system nameservers (1.1.1.1, 8.8.8.8) are set under System → Settings → General → DNS Servers.

**DNSSEC failure:**

```bash
# Test if DNSSEC is causing the issue
drill -D google.com @10.0.0.1

# If DNSSEC validation fails, temporarily disable to confirm
# WebGUI → Services → Unbound DNS → General → uncheck DNSSEC
# Apply, test, then investigate the DNSSEC issue
```

### 8.3 External Works, Internal Fails

**Symptoms:**
- `dig @10.0.0.1 google.com` works
- `dig @10.0.0.1 talos-cp-1.homelab.local` fails (NXDOMAIN)
- K8s nodes can reach the internet but can't resolve local names

**Triage:**

```bash
# Check host overrides
cat /var/unbound/unbound.conf | grep "local-data"

# Check the domain
cat /var/unbound/unbound.conf | grep "local-zone"
```

**Fix:** Verify host overrides in WebGUI → Services → Unbound DNS → Host Overrides match the entries in the [configuration guide](opnsense-configuration-guide.md):

| Host | Domain | IP |
|------|--------|-----|
| talos-cp-1 | homelab.local | 10.0.0.10 |
| talos-cp-2 | homelab.local | 10.0.0.11 |
| talos-cp-3 | homelab.local | 10.0.0.12 |
| k8s-api | homelab.local | 10.0.0.5 |

### 8.4 DNS Slow

**Symptoms:**
- DNS queries take 2-10+ seconds instead of <100ms
- Web browsing feels sluggish, but downloads at full speed once connected

**Common causes and fixes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| DNSSEC validation timeout | `drill -D google.com @10.0.0.1` is slow | Check system clock (`date`), or temporarily disable DNSSEC |
| Slow upstream DNS | `drill google.com @1.1.1.1` is slow | Switch forwarders (try 9.9.9.9 or 208.67.222.222) |
| DNS cache empty after restart | Slow after Unbound restart, improves over time | Normal — cache will warm up |
| High CPU on OPNsense | `top` shows high utilization | See [Section 15.1](#151-high-cpu) |

**Flush DNS cache (if stale records are suspected):**

```bash
# From OPNsense console
service unbound restart
# or via WebGUI → Services → Unbound DNS → General → Flush DNS Cache
```

**Flush DNS cache on client:**

```bash
# Linux
sudo systemd-resolve --flush-caches   # systemd-resolved
# or
sudo resolvectl flush-caches           # newer systemd

# macOS
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

### 8.5 DNS Test Matrix

Run these tests from your workstation to pinpoint the failure:

| Test Command | Success Means | Failure Means |
|-------------|---------------|---------------|
| `dig @10.0.0.1 google.com` | Unbound is running and forwarding | Unbound down or forwarding broken |
| `dig @1.1.1.1 google.com` | Upstream DNS reachable, WAN works | WAN or NAT issue (not DNS) |
| `dig @10.0.0.1 talos-cp-1.homelab.local` | Host overrides working | Missing host override |
| `dig @10.0.0.1 google.com +dnssec` | DNSSEC validation working | DNSSEC misconfigured |
| `dig @10.0.0.1 google.com +tcp` | TCP DNS works | Firewall blocking TCP/53 |
| `ping 10.0.0.1` then `dig @10.0.0.1 ...` | Separate reachability from DNS | If ping works but dig fails → port 53 blocked |

### 8.6 Unbound DNS Not Running Despite Correct Configuration

**Symptoms:**
- Unbound shows as "stopped" in Services → Unbound DNS status
- `service unbound status` returns "unbound is not running"
- All DNS settings appear correct in the WebGUI (enabled, correct interfaces, forwarding configured)
- Restarting via WebGUI or `service unbound start` fails silently or starts then immediately stops
- All name resolution from LAN fails, but IP-based connectivity works

**This is a known pattern on OPNsense 25.x. However, first rule out a false alarm — Unbound may actually be running fine.**

**Step-by-step diagnosis:**

**0. First check: Is Unbound actually running? (PID file mismatch)**

> [!IMPORTANT]
> **Real-world finding:** `service unbound status` can report "not running" even when Unbound IS running and serving DNS correctly. This happens when the PID file (`/var/run/unbound.pid`) gets out of sync with the actual process — common after OPNsense updates or unclean restarts.

```bash
# Check if unbound is actually listening on port 53
sockstat -4 -l | grep :53

# Check the actual process
pgrep -l unbound

# Test DNS directly
dig @10.0.0.1 google.com
```

If `sockstat` shows unbound on port 53 and `dig` works, **Unbound IS running** — the `service` command is just confused. Fix the PID file:

```bash
# Update PID file to match running process
pgrep -f "/var/unbound/unbound.conf" > /var/run/unbound.pid
# Verify
service unbound status
```

If Unbound is genuinely not running (nothing on port 53, dig fails), continue with the steps below.

**1. Check for configuration validation errors**

```bash
unbound-checkconf /var/unbound/unbound.conf
```

Unbound will refuse to start if config validation fails. The WebGUI may not show the error. If errors appear, they will point to the exact line and problem in the config.

**2. Check for port 53 conflicts**

```bash
sockstat -4 -l | grep :53
```

If Dnsmasq or another DNS service is running (common after migration or plugin changes), it occupies port 53 and Unbound cannot bind. If you see a process other than `unbound`:

```bash
# Identify and stop the conflicting service
service <conflicting-service> stop
# Then start Unbound
service unbound start
```

**3. Check system logs for the actual error**

```bash
grep -i unbound /var/log/system/latest.log | tail -30
```

The actual failure reason is almost always in the system log even when the WebGUI shows nothing. Common errors:
- `could not bind to port 53` → port conflict (step 2)
- `error reading root anchor` → DNSSEC root anchor issue (step 6)
- `fatal error: out of memory` → memory issue (step 7)
- `cannot open /var/unbound/unbound.conf` → config file missing or permissions

**4. Check if the service is enabled in the backend**

```bash
sysrc -a | grep unbound
```

Sometimes FreeBSD's `rc.conf` does not have `unbound_enable="YES"` even though the WebGUI shows Unbound as enabled. This can happen after updates or config resets.

```bash
# Fix if missing
sysrc unbound_enable=YES
service unbound start
```

**5. Check for stale PID file**

```bash
ls -la /var/run/unbound.pid
```

A stale PID file from a crash can prevent Unbound from starting (it thinks another instance is running).

```bash
# Fix: remove stale PID and start
rm /var/run/unbound.pid
service unbound start
```

**6. Check for DNSSEC root anchor issues**

```bash
ls -la /var/unbound/root.key
```

If the root trust anchor file is missing or corrupted (common after fresh install or major OPNsense update), Unbound with DNSSEC enabled will fail to start.

```bash
# Regenerate the root anchor
unbound-anchor -a /var/unbound/root.key
service unbound start
```

If this fails, temporarily disable DNSSEC in WebGUI → Services → Unbound DNS → General → uncheck "DNSSEC" → Apply, then investigate the root anchor issue separately.

**7. Check available memory**

```bash
top -b -n 1 | head -5
```

Unbound can fail to start or crash immediately if the VM is low on memory. This is especially common if:
- Large DNS blocklists are configured (adblock plugin)
- The OPNsense VM only has 2GB RAM
- Other services are consuming memory

Fix: Increase VM memory in Proxmox (`qm set 101 -memory 4096`) or reduce blocklist size.

**8. Nuclear option: toggle via WebGUI**

If all else fails, force OPNsense to regenerate the config from scratch:

1. WebGUI → Services → Unbound DNS → General → **uncheck** "Enable Unbound" → Save → Apply
2. Wait 10 seconds
3. **Re-check** "Enable Unbound" → Save → Apply

This forces OPNsense to regenerate `/var/unbound/unbound.conf` from the WebGUI settings, bypassing any manual config corruption.

**Diagnostic summary:**

| Check | Command | Expected | If Wrong |
|-------|---------|----------|----------|
| Config valid | `unbound-checkconf /var/unbound/unbound.conf` | "no errors" | Fix the config errors shown |
| Port 53 free | `sockstat -4 -l \| grep :53` | Empty or `unbound` only | Stop conflicting service |
| Service enabled | `sysrc -a \| grep unbound` | `unbound_enable=YES` | `sysrc unbound_enable=YES` |
| No stale PID | `ls /var/run/unbound.pid` | File missing or current PID | `rm /var/run/unbound.pid` |
| Root anchor exists | `ls /var/unbound/root.key` | File exists, recent date | `unbound-anchor -a /var/unbound/root.key` |
| Sufficient memory | `top -b -n 1` | Free mem > 100MB | Increase VM memory or reduce blocklists |
| Logs show cause | `grep -i unbound /var/log/system/latest.log` | No fatal errors | Address the specific error |

> [!TIP]
> **Collecting logs for offline analysis:** Use `scripts/collect-opnsense-logs.sh` to pull Unbound logs, Kea logs, configs, and service status from OPNsense via SSH. This is useful when the WebGUI doesn't surface errors clearly.
> ```bash
> ./scripts/collect-opnsense-logs.sh              # defaults to root@10.0.0.1
> ./scripts/collect-opnsense-logs.sh 192.168.1.x  # use WAN IP if LAN is down
> ```

---

## 9. NAT & Routing Failures

### 9.1 LAN→Internet Broken

**Symptoms:**
- LAN clients can reach 10.0.0.1 (gateway) but not the internet
- `ping 8.8.8.8` fails from LAN clients
- DNS may or may not work (depending on cache)

> [!IMPORTANT]
> First test from OPNsense itself to distinguish between a WAN issue and a NAT issue.

```bash
# From OPNsense console
ping 8.8.8.8
ping 1.1.1.1
```

- **If OPNsense can ping the internet:** The WAN is fine. Problem is NAT or routing between LAN and WAN → continue below.
- **If OPNsense cannot ping the internet:** WAN interface issue → [Section 6.2](#62-wan-interface-down-vtnet0).

### 9.2 NAT Rules Missing

```bash
# From OPNsense console
pfctl -s nat
# Expected output should include:
# nat on vtnet0 from 10.0.0.0/24 to any -> (vtnet0) round-robin
```

If no NAT rules are listed:

**Check NAT mode:**
- WebGUI → Firewall → NAT → Outbound
- Should be set to **Automatic outbound NAT rule generation**

**If WebGUI is unreachable, check from console:**

```bash
# Regenerate NAT rules
configctl filter reload
# or
pfctl -f /tmp/rules.debug
```

### 9.3 Routing Table Issues

```bash
# From OPNsense console
netstat -rn
```

**Expected key routes:**

| Destination | Gateway | Interface | Notes |
|-------------|---------|-----------|-------|
| default | 192.168.1.1 | vtnet0 | Default route via main router |
| 10.0.0.0/24 | link#2 | vtnet1 | LAN subnet directly connected |
| 192.168.1.0/24 | link#1 | vtnet0 | WAN subnet directly connected |

**Missing default route:**

```bash
# Add default route manually
route add default 192.168.1.1

# Permanent fix: check WAN interface config
# WebGUI → Interfaces → WAN → IPv4 Upstream Gateway should be set
```

**Missing LAN route:**

```bash
# This means vtnet1 is not configured correctly
ifconfig vtnet1 inet 10.0.0.1 netmask 255.255.255.0
```

### 9.4 Asymmetric Routing

**Symptoms:**
- Connections from WAN to MetalLB services (10.0.0.50-99) are dropped
- SYN packets arrive but SYN-ACK never returns
- pfctl shows state table entries as "NO_TRAFFIC"

**Cause:** OPNsense's stateful firewall expects return traffic on the same interface as the initial connection. MetalLB or VIP traffic may take asymmetric paths.

**Diagnosis:**

```bash
# From OPNsense console
pfctl -s state | grep 10.0.0.5
# Look for states with unusual flag combinations
```

**Fixes:**

1. **Disable state tracking for specific rules** (for MetalLB traffic):
   - WebGUI → Firewall → Rules → LAN
   - Edit the relevant rule → Advanced → State Type → **Sloppy State**

2. **Enable "Allow anti-spoof" option** if traffic is being dropped by anti-spoof rules.

### 9.5 Specific Sites/Ports Blocked

**Symptoms:**
- Most internet works but certain sites/services don't
- Some ports are blocked (e.g., SSH outbound, custom ports)

**Triage:**

```bash
# From OPNsense console — check firewall log for blocks
cat /var/log/filter/latest.log | tail -100

# Check if DNS blocklist is the cause (ad blocking)
# Try resolving the blocked domain directly
drill blocked-site.com @1.1.1.1
# vs
drill blocked-site.com @10.0.0.1
# If the first works but second returns 0.0.0.0 → it's the DNS blocklist
```

If it's an ad-blocker false positive, see [opnsense-adblock-guide.md](opnsense-adblock-guide.md) for whitelist configuration.

**NAT packet flow for reference:**

```
LAN Client (10.0.0.100)                    OPNsense                         Internet
        │                                      │                                │
        │  src: 10.0.0.100                     │                                │
        │  dst: 8.8.8.8         ──────────▶    │                                │
        │                                      │   NAT: src → WAN IP            │
        │                                      │   dst: 8.8.8.8   ──────────▶  │
        │                                      │                                │
        │                                      │   src: 8.8.8.8                 │
        │                                      │   dst: WAN IP    ◀──────────  │
        │                                      │   De-NAT: dst → 10.0.0.100    │
        │  src: 8.8.8.8                        │                                │
        │  dst: 10.0.0.100     ◀──────────     │                                │
        │                                      │                                │
```

---

## 10. Firewall Rule Issues

### 10.1 Rule Evaluation Order

OPNsense evaluates firewall rules in a specific order. Understanding this is critical for debugging:

```
1. Floating rules (if "quick" is set, evaluation stops on match)
        │
        ▼
2. Interface-specific rules (WAN, LAN, etc.)
   - Evaluated top-to-bottom
   - First match wins
        │
        ▼
3. Implicit deny (if no rule matched, traffic is BLOCKED)
```

**Key points:**
- Rules are processed **first match wins**, not last match
- The implicit deny at the end blocks anything not explicitly allowed
- Floating rules with "quick" flag bypass interface rules entirely
- Rule order on each interface tab matters — move more specific rules above general ones

### 10.2 Legitimate Traffic Blocked

**Symptoms:**
- Specific services unreachable despite connectivity otherwise working
- Connection timeouts on certain ports
- Firewall log shows blocks for traffic that should be allowed

**Diagnosis — live firewall log:**

```bash
# From OPNsense console
tail -f /var/log/filter/latest.log
# Generate the blocked traffic from the client
# Look for: block entries with src/dst matching your traffic
```

Or via WebGUI → Firewall → Log Files → Live View:
- Filter by source IP, destination IP, or port
- Look for red (blocked) entries

**Common fix:** Ensure the LAN → Any rule exists:

- WebGUI → Firewall → Rules → LAN
- Should have a rule: Action=Pass, Source=LAN net, Destination=Any
- If missing, add it (see [configuration guide](opnsense-configuration-guide.md), Section 4)

### 10.3 Anti-Lockout Rule Disabled

**Symptoms:**
- Cannot reach OPNsense WebGUI on LAN (https://10.0.0.1)
- SSH to OPNsense also fails
- OPNsense is running (can verify via Proxmox console)

The anti-lockout rule prevents you from accidentally blocking WebGUI/SSH access from the LAN. If it's disabled:

**Fix from OPNsense console (Proxmox noVNC):**

```bash
# Option 1: Temporarily disable the firewall
pfctl -d
# Access WebGUI, re-enable anti-lockout rule
# Firewall → Settings → Advanced → Check "Disable anti-lockout"
# Re-enable firewall
pfctl -e

# Option 2: Use console menu
# Select option 11 (Restore a configuration backup)
# Choose a backup from before the anti-lockout was disabled
```

### 10.4 K8s-Specific Firewall Issues

**MetalLB traffic (10.0.0.50-99):**

MetalLB uses ARP announcements to claim IPs in the 10.0.0.50-99 range. OPNsense needs to allow this traffic.

```bash
# Check if ARP is being processed correctly
# From OPNsense console
arp -a | grep "10.0.0.5"
# Should show the MAC of the node hosting the VIP
```

**K8s API VIP (10.0.0.5:6443):**

```bash
# Test from OPNsense console
nc -z 10.0.0.5 6443
# Should connect — if not, the VIP is a Talos issue, not OPNsense
```

**Required firewall rules for K8s:**

| Rule | Source | Destination | Port | Purpose |
|------|--------|-------------|------|---------|
| LAN → Any | LAN net | Any | Any | General LAN access (covers all K8s traffic) |
| Inter-node | LAN net | LAN net | 6443, 2379-2380, 10250 | K8s control plane (covered by LAN→Any) |
| MetalLB | LAN net | 10.0.0.50-99 | Any | LoadBalancer services (covered by LAN→Any) |

> [!NOTE]
> If you have the default "Allow LAN to Any" rule, all K8s internal traffic is already permitted. You only need specific rules if you've replaced the default with more restrictive rules.

### 10.5 pfctl Reference

Essential `pfctl` commands for firewall debugging:

| Command | Description |
|---------|-------------|
| `pfctl -s rules` | Show all loaded firewall rules |
| `pfctl -s nat` | Show NAT rules |
| `pfctl -s state` | Show active state table (connections) |
| `pfctl -s info` | Show firewall statistics |
| `pfctl -s Interfaces` | Show interface statistics |
| `pfctl -d` | Disable firewall (allow all traffic) |
| `pfctl -e` | Enable firewall |
| `pfctl -f /tmp/rules.debug` | Reload rules from file |
| `pfctl -s state \| grep <IP>` | Find states for a specific IP |
| `pfctl -k <IP>` | Kill all states for an IP |
| `pfctl -F states` | Flush all states (drop all connections) |

> [!WARNING]
> `pfctl -F states` will drop ALL active connections including your SSH session. Use with caution.

---

## 11. WebGUI Access Issues

### 11.1 Unreachable from WAN

**Symptoms:**
- Cannot reach `https://<WAN-IP>` from the 192.168.1.x network
- Can reach OPNsense via LAN or console

**Triage:**

```bash
# From OPNsense console
# Check what lighttpd is listening on
sockstat -4 -l | grep :443
# Should show lighttpd on 0.0.0.0:443 or specific interfaces

# Check WAN IP
ifconfig vtnet0 | grep inet
```

**Common causes:**

| Cause | Fix |
|-------|-----|
| WAN firewall blocks WebGUI | By design — add WAN rule or use `pfctl -d` temporarily |
| Listen interface set to LAN only | WebGUI → System → Settings → Administration → Listen Interfaces → All |
| WAN IP changed (DHCP renewal) | Check new IP via console `ifconfig vtnet0` |

### 11.2 Unreachable from LAN

**Symptoms:**
- Cannot reach `https://10.0.0.1` from LAN clients
- LAN connectivity otherwise works (DHCP, DNS)

**Triage:**

```bash
# From OPNsense console
# Is lighttpd running?
service lighttpd status

# If not running
service lighttpd start

# Check if port 443 is listening
sockstat -4 -l | grep :443

# Check if anti-lockout rule is active
pfctl -s rules | grep "anti-lockout"
```

**If lighttpd crashed:**

```bash
# Check error log
cat /var/log/lighttpd/error.log | tail -20

# Common fix: PHP issue after update
service php-fpm restart
service lighttpd restart
```

### 11.3 TLS Certificate Errors

**Symptoms:**
- Browser shows "Your connection is not private" / "Certificate expired"
- ERR_CERT_DATE_INVALID or similar errors

OPNsense uses a self-signed certificate by default. Browsers will always warn about this — that's expected. But if the certificate has expired:

**Regenerate self-signed certificate from console:**

```bash
# From OPNsense console
configctl webgui renew cert
service lighttpd restart
```

Or via WebGUI (if accessible with certificate exception):
- System → Trust → Certificates → find the WebGUI certificate → Regenerate

### 11.4 Login Failures

**Symptoms:**
- WebGUI loads but login fails
- "Invalid username or password" despite correct credentials

**Reset root password from console:**

1. Access OPNsense via Proxmox noVNC console
2. Log in as `root` at the console (console login is separate from WebGUI)
3. Select menu option **3** (Reset the root password)
4. Enter new password
5. Try WebGUI login again

If console login also fails:
- Boot into single-user mode ([Section 5.2](#52-boot-loop--kernel-panic))
- Edit `/conf/config.xml` and reset the password hash

---

## 12. API Troubleshooting

### 12.1 Authentication Failures (401/403)

**Symptoms:**
- API calls return HTTP 401 (Unauthorized) or 403 (Forbidden)
- Terraform `opnsense` provider fails with authentication errors
- `curl` to API endpoints returns permission denied

**Triage:**

```bash
# Test API authentication
curl -k -u "your-key:your-secret" \
  https://10.0.0.1/api/core/firmware/status
```

**Common causes:**

| HTTP Code | Cause | Fix |
|-----------|-------|-----|
| 401 | Invalid key or secret | Regenerate: WebGUI → System → Access → Users → API keys |
| 403 | User not in admins group | WebGUI → System → Access → Groups → add user to admins |
| 401 | Key/secret have trailing whitespace | Copy credentials again, trim whitespace |

**Regenerate API key:**

1. WebGUI → System → Access → Users → edit `root` (or API user)
2. Scroll to API keys → click **+** to generate new key
3. Download both key and secret files
4. Update your environment variables:

```bash
export OPNSENSE_API_KEY="new-key"
export OPNSENSE_API_SECRET="new-secret"
```

### 12.2 Endpoint Unreachable

API runs on the same HTTPS server as the WebGUI. If the API endpoint is unreachable, the root cause is the same as WebGUI access issues:

- From LAN → [Section 11.2](#112-unreachable-from-lan)
- From WAN → [Section 11.1](#111-unreachable-from-wan)

### 12.3 Unexpected Results

**Symptoms:**
- API returns 200 OK but with unexpected data
- Terraform plan shows unexpected changes
- Settings don't match what the API reports

**Common causes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| OPNsense was updated | `opnsense-version` shows newer version | Check provider compatibility, update provider |
| API schema changed | Compare API docs for old vs new version | Pin OPNsense version or update Terraform provider |
| Config applied but not saved | WebGUI shows pending changes | Apply pending changes in WebGUI |

```bash
# Check OPNsense version
curl -k -u "key:secret" https://10.0.0.1/api/core/firmware/status | python3 -m json.tool
```

### 12.4 Testing with curl

**Basic API health check:**

```bash
curl -k -u "key:secret" https://10.0.0.1/api/core/firmware/status
```

**List DHCP leases:**

```bash
curl -k -u "key:secret" https://10.0.0.1/api/dhcpv4/leases/searchLease
```

**Get firewall rules:**

```bash
curl -k -u "key:secret" https://10.0.0.1/api/firewall/filter/searchRule
```

**Get interface status:**

```bash
curl -k -u "key:secret" https://10.0.0.1/api/diagnostics/interface/getInterfaceStatistics
```

> [!NOTE]
> Always use `-k` flag to skip TLS verification (self-signed cert). Use `-s` for scripting to suppress progress output.

---

## 13. Post-Update Breakage

### 13.1 Identifying Update Issues

After an OPNsense update, services may behave differently or break entirely.

```bash
# Check current version
opnsense-version
# Example: OPNsense 25.7

# Check installed package versions
pkg info | head -20

# Check for recent error messages
grep -i error /var/log/system/latest.log | tail -20

# Check if services restarted properly
service -e    # List enabled services
```

### 13.2 Common Post-Update Failures

| Problem | Symptoms | Fix |
|---------|----------|-----|
| Unbound config format change | DNS stops working after update | Check `/var/unbound/unbound.conf` for new syntax, reconfigure via WebGUI |
| PHP version bump | WebGUI 500 errors, API failures | `service php-fpm restart`, check PHP error log |
| virtio driver changes | Interface names change, VTnet issues | Reassign interfaces via console menu option 1 |
| Plugin incompatibility | Specific plugins crash or misbehave | Disable plugin, check for plugin update |
| Firewall rule migration | Rules reordered or reset | Review Firewall → Rules, reorder if needed |
| DHCP config format change | DHCP stops serving leases | Reconfigure DHCP via WebGUI |

### 13.3 Rolling Back

**Option 1: Restore OPNsense configuration backup**

If the issue is configuration-related (not a binary/package issue):

1. WebGUI → System → Configuration → Backups
2. Select a backup from before the update
3. Restore → Reboot

**Option 2: Proxmox snapshot rollback**

If you took a snapshot before updating (you should always do this):

```bash
# From Proxmox host
# List available snapshots
qm listsnapshot 101

# Stop VM first
qm stop 101

# Rollback to the pre-update snapshot
qm rollback 101 --snapname pre-update

# Start VM
qm start 101
```

> [!CAUTION]
> Snapshot rollback reverts the entire VM to the snapshot state. All changes since the snapshot (config changes, logs, DHCP leases) will be lost. This is a full state revert, not just a config restore.

### 13.4 Pre-Update Checklist

Do this **before** every OPNsense update:

1. **Create Proxmox snapshot:**

```bash
# From Proxmox host
qm snapshot 101 --snapname pre-update-$(date +%Y%m%d) --description "Before OPNsense update"
```

2. **Download configuration backup:**
   - WebGUI → System → Configuration → Backups → Download

3. **Document current working state:**

```bash
# From OPNsense console
opnsense-version              # Record current version
ifconfig -a                    # Record interface state
pfctl -s rules | wc -l        # Record rule count
pluginctl -s dhcpd             # Record DHCP status
service unbound status         # Record DNS status
```

4. **Check release notes** for breaking changes at opnsense.org

---

## 14. Configuration Corruption & Recovery

### 14.1 Detecting Corruption

**Symptoms:**
- WebGUI fails to load specific pages (500 error)
- Services fail to start with XML parse errors
- Console shows config-related errors on boot

**Diagnosis:**

```bash
# From OPNsense console
# Check if config.xml is valid XML
xmllint /conf/config.xml
# If it reports errors, the config is corrupted

# Check config file size (should be >10KB for a configured system)
ls -la /conf/config.xml

# Check for backup configs
ls -la /conf/backup/
```

### 14.2 Restore from OPNsense Backup

**Via WebGUI (if partially working):**

1. System → Configuration → Backups
2. Click "Restore" tab
3. Upload a known-good backup file
4. Apply → Reboot

**Via console (if WebGUI is broken):**

```bash
# List available backups
ls -lt /conf/backup/ | head -10

# Copy a recent backup over the current config
cp /conf/backup/config-XXXXXXXX.xml /conf/config.xml

# Reboot to apply
reboot
```

### 14.3 Restore from Proxmox Snapshot

```bash
# From Proxmox host
# List snapshots
qm listsnapshot 101

# Example output:
# `-- current (You are here!)
#  `-- pre-update-20260315 (Before OPNsense update)
#   `-- initial-setup (Clean install with base config)

# Rollback
qm stop 101
qm rollback 101 --snapname pre-update-20260315
qm start 101
```

### 14.4 Factory Reset (Last Resort)

If no backups exist and the configuration is unrecoverable:

1. Access OPNsense via Proxmox noVNC console
2. Login as root
3. Select console menu option **4** (Reset to factory defaults)
4. Confirm
5. OPNsense reboots with default settings
6. Reconfigure from scratch using the [configuration guide](opnsense-configuration-guide.md)

> [!CAUTION]
> Factory reset wipes ALL configuration — firewall rules, DHCP settings, DNS overrides, static mappings, API keys. The entire K8s cluster will lose DHCP/DNS until reconfiguration is complete.

---

## 15. Performance Degradation

### 15.1 High CPU

**Symptoms:**
- WebGUI is sluggish
- Packet loss or high latency through OPNsense
- DNS queries slow

**Diagnosis from OPNsense console:**

```bash
# Check top processes
top -b -n 1 | head -20

# Check system load
uptime

# Common CPU hogs
# - suricata (IDS/IPS) — very resource-intensive
# - clamd (ClamAV) — antivirus scanning
# - unbound — under heavy DNS load
# - php-fpm — WebGUI processing
```

**Fixes:**

| Process | Fix |
|---------|-----|
| suricata | Disable IDS/IPS if not needed: Services → Intrusion Detection → uncheck Enable |
| clamd | Disable ClamAV: Services → ClamAV → uncheck Enable |
| unbound | Check for DNS amplification or misconfigured forwarders |
| php-fpm | Restart: `service php-fpm restart` |

**Check Proxmox CPU allocation:**

```bash
# From Proxmox host
qm config 101 | grep cores
# If only 2 cores, consider increasing

# Increase to 4 cores (VM must be stopped)
qm stop 101
qm set 101 -cores 4
qm start 101
```

### 15.2 Memory Pressure

**Symptoms:**
- OPNsense processes killed by OOM
- Swap usage is high
- Services fail to start with "out of memory" errors

**Diagnosis from OPNsense console:**

```bash
# Memory overview
top -b -n 1 | head -5
# Look for Mem: line

# Detailed memory
vmstat -h
sysctl hw.physmem hw.usermem
```

**From Proxmox host:**

```bash
# Check VM memory config
qm config 101 | grep memory
# Default: 6144 (6GB)

# Increase if needed (VM must be stopped)
qm stop 101
qm set 101 -memory 8192
qm start 101
```

### 15.3 Packet Drops / Latency

**Symptoms:**
- Intermittent connectivity
- Ping shows packet loss
- TCP connections stall

**Diagnosis from OPNsense console:**

```bash
# Check interface error counters
netstat -i
# Look for Ierrs, Oerrs, Coll columns

# Check for interface drops
sysctl dev.vtnet0.stats
sysctl dev.vtnet1.stats

# Check pf state table usage
pfctl -s info | grep -i state
# If current states are near the limit, increase it
```

**From Proxmox host:**

```bash
# Check for bridge drops
ip -s link show vmbr0
ip -s link show vmbr1
# Look for dropped/errors counters
```

**Fixes:**

| Cause | Fix |
|-------|-----|
| State table full | WebGUI → Firewall → Settings → Advanced → increase "Firewall Maximum States" |
| Duplex mismatch | Check switch port settings match NIC settings (auto/auto or 1G/full both sides) |
| Virtio ring buffer exhaustion | Increase ring buffer size in VM config (advanced) |

### 15.4 Disk I/O

**Symptoms:**
- Configuration saves are slow
- Log viewing is sluggish
- Boot takes longer than usual

**Diagnosis from OPNsense console:**

```bash
# Check disk usage
df -h

# Check for I/O wait
top -b -n 1 | head -5
# Look for high "wa" (I/O wait) percentage
```

**From Proxmox host:**

```bash
# Check VM disk type and storage
qm config 101 | grep virtio
# virtio0 should be on fast storage (SSD preferred)

# Check host disk I/O
iostat -x 1 5
```

---

## 16. VLAN-Related Lockouts

> [!TIP]
> For comprehensive VLAN setup and recovery procedures, see [opnsense-vlan-setup.md](opnsense-vlan-setup.md).

### 16.1 Quick Recovery

If you've locked yourself out after a VLAN change, here's the condensed recovery:

1. **Access Proxmox noVNC console** → `https://192.168.1.110:8006` → VM 101 → Console

2. **Login to OPNsense console** as root

3. **Select option 1** — Assign interfaces

4. **Reassign LAN back to vtnet1** (not a VLAN sub-interface):
   - Do you want to configure VLANs? → **No**
   - WAN interface → `vtnet0`
   - LAN interface → `vtnet1`
   - Confirm

5. **Select option 2** — Set interface IP addresses
   - Select LAN (option 2)
   - Configure IPv4: `10.0.0.1`
   - Subnet mask: `24`
   - No upstream gateway (this is LAN)
   - Enable DHCP: Yes
   - Start: `10.0.0.100`
   - End: `10.0.0.200`

6. **Verify** from a LAN client:

```bash
# Linux
sudo dhclient -v eth0
ping 10.0.0.1

# macOS
sudo ipconfig set en0 DHCP
ping 10.0.0.1
```

### 16.2 Prevention Checklist

Before making any VLAN changes:

- [ ] Create a Proxmox snapshot: `qm snapshot 101 --snapname pre-vlan`
- [ ] Ensure you can reach Proxmox WebGUI (192.168.1.110:8006) independently of LAN
- [ ] Have this guide open on a device connected to WAN (not LAN)
- [ ] Know how to use the OPNsense console menu for interface reassignment
- [ ] Read [opnsense-vlan-setup.md](opnsense-vlan-setup.md) Section 5 before starting

---

## 17. Kubernetes-Specific OPNsense Issues

### 17.1 K8s API VIP Unreachable

**Symptoms:**
- `kubectl` commands fail: "Unable to connect to the server"
- `ping 10.0.0.5` fails or inconsistent
- Individual control planes (10.0.0.10-12) may or may not be reachable

**Distinguish OPNsense vs Talos issue:**

```bash
# Can you reach individual control planes?
ping 10.0.0.10
ping 10.0.0.11
ping 10.0.0.12

# Can you reach the VIP?
ping 10.0.0.5
```

| Ping CPs | Ping VIP | Likely Issue |
|-----------|----------|-------------|
| All fail | Fails | OPNsense or network issue (DHCP/routing) |
| Some work | Fails | Talos VIP issue — VIP not assigned to any node |
| All work | Fails | Talos VIP issue — VIP not claimed |
| All work | Works | Issue is elsewhere (kubeconfig, port 6443) |

**If OPNsense is the issue:**
- Check DHCP leases: Are control planes getting their static IPs?
- Check ARP table: `arp -a | grep "10.0.0.5"` on OPNsense
- Check firewall: Is traffic to 10.0.0.5:6443 being blocked?

**If Talos is the issue:**
- See [talos-management-handbook.md](talos-management-handbook.md) for Talos-side troubleshooting
- Check VIP status: `talosctl get addresses --nodes 10.0.0.10`

### 17.2 MetalLB Services Unreachable

**Symptoms:**
- `kubectl get svc` shows EXTERNAL-IP in 10.0.0.50-99 range
- Cannot reach the service from LAN clients
- Service works within the cluster (pod-to-pod via ClusterIP)

**Triage:**

```bash
# Check if OPNsense has an ARP entry for the MetalLB IP
# From OPNsense console
arp -a | grep "10.0.0.5"

# Check if traffic is being blocked
grep "10.0.0.5" /var/log/filter/latest.log
```

**Common causes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| ARP not propagated | `arp -a` on OPNsense shows no entry for MetalLB IP | MetalLB L2 mode sends gratuitous ARPs — check MetalLB config |
| Firewall blocking | Entries in filter.log | Add/fix firewall rule for MetalLB range |
| Not on same L2 segment | Client on different VLAN/subnet | Ensure client is on 10.0.0.0/24 |

**Force ARP refresh on your workstation:**

```bash
# Linux
sudo ip neigh flush dev eth0

# macOS
sudo arp -d -a
```

### 17.3 Inter-Node Communication

OPNsense is **not** in the data path for inter-node traffic — Talos nodes communicate directly over the LAN switch at Layer 2. However, OPNsense failures cascade to K8s because:

1. **DHCP:** If leases expire and nodes can't renew, they eventually lose their IPs
2. **DNS:** CoreDNS on K8s pods may forward to Unbound on OPNsense
3. **NAT:** Nodes can't pull container images from the internet

**If inter-node communication fails:**

```bash
# Check if nodes can ping each other (from a node via talosctl)
talosctl -n 10.0.0.10 ping 10.0.0.11

# If they can't, the issue is Layer 2 (switch/cables), not OPNsense
# Check switch port configuration at 10.0.0.2
```

### 17.4 Pod DNS Resolution

Pods use CoreDNS (running in the cluster) for DNS. CoreDNS may forward external queries to OPNsense's Unbound.

**DNS chain:**

```
Pod → CoreDNS (cluster) → Unbound (OPNsense 10.0.0.1) → 1.1.1.1 / 8.8.8.8
```

**If pod DNS fails but host DNS works:**
- Issue is likely CoreDNS, not OPNsense
- See [talos-management-handbook.md](talos-management-handbook.md) for CoreDNS troubleshooting

**If both pod and host DNS fail:**
- OPNsense Unbound is down → [Section 8.1](#81-total-dns-failure)

**Test from a node:**

```bash
# Check what DNS server nodes are using
talosctl -n 10.0.0.10 read /etc/resolv.conf

# Test DNS from the node level
talosctl -n 10.0.0.10 dns-resolve google.com
```

---

## Appendix A: Command Reference (Linux vs macOS)

| Task | Linux | macOS |
|------|-------|-------|
| Show IP addresses | `ip addr show` | `ifconfig` |
| Show specific interface | `ip addr show dev eth0` | `ifconfig en0` |
| Add static IP | `sudo ip addr add 10.0.0.199/24 dev eth0` | `sudo networksetup -setmanual "Ethernet" 10.0.0.199 255.255.255.0 10.0.0.1` |
| Remove static IP | `sudo ip addr del 10.0.0.199/24 dev eth0` | `sudo networksetup -setdhcp "Ethernet"` |
| Show routing table | `ip route show` | `netstat -rn` |
| Add default route | `sudo ip route add default via 10.0.0.1` | `sudo route add default 10.0.0.1` |
| Delete default route | `sudo ip route del default` | `sudo route delete default` |
| Show ARP table | `ip neigh show` | `arp -a` |
| Flush ARP | `sudo ip neigh flush dev eth0` | `sudo arp -d -a` |
| Flush DNS cache | `sudo systemd-resolve --flush-caches` | `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` |
| Show listening ports | `ss -tlnp` | `lsof -iTCP -sTCP:LISTEN -n -P` |
| Packet capture | `sudo tcpdump -i eth0 -n` | `sudo tcpdump -i en0 -n` |
| DHCP release/renew | `sudo dhclient -r eth0 && sudo dhclient eth0` | `sudo ipconfig set en0 DHCP` |
| DHCP verbose | `sudo dhclient -v eth0` | `ipconfig getpacket en0` |
| Test TCP port | `nc -zv 10.0.0.1 443` | `nc -zv 10.0.0.1 443` |
| DNS lookup | `dig @10.0.0.1 google.com` | `dig @10.0.0.1 google.com` |
| Trace route | `traceroute 8.8.8.8` | `traceroute 8.8.8.8` |
| Interface names | `eth0`, `enp3s0`, `wlan0` | `en0` (Ethernet), `en1` (WiFi) |
| Network manager | `nmcli` / `systemctl restart NetworkManager` | `networksetup` |

---

## Appendix B: OPNsense Console Menu Reference

When you access OPNsense via Proxmox noVNC console and log in as root, you see:

| Option | Description | When to Use |
|--------|-------------|-------------|
| 0 | Logout | Exit console session |
| 1 | Assign interfaces | Fix VLAN lockout, reassign WAN/LAN after NIC changes |
| 2 | Set interface IP address | Fix missing LAN/WAN IP, reconfigure DHCP |
| 3 | Reset the root password | Locked out of WebGUI login |
| 4 | Reset to factory defaults | Last resort — wipes all config |
| 5 | Power off system | Graceful shutdown |
| 6 | Reboot system | Apply changes that require reboot |
| 7 | Ping host | Test connectivity from OPNsense |
| 8 | Shell | Drop to FreeBSD shell for advanced debugging |
| 9 | pfTop | Live view of firewall state table |
| 10 | Firewall log | View recent firewall events |
| 11 | Restore a configuration backup | Revert to a previous config.xml |
| 12 | PHP shell | Interactive PHP for OPNsense internals |
| 13 | Update from console | Apply firmware updates without WebGUI |
| 14 | Enable Secure Shell (sshd) | Turn on SSH if disabled |

> [!TIP]
> Option **8** (Shell) is the most powerful — it gives you a full FreeBSD shell where you can run all `pfctl`, `ifconfig`, `service`, and diagnostic commands documented in this guide.

---

## Appendix C: Proxmox qm Command Reference for VM 101

All commands run from the Proxmox host (SSH to 192.168.1.110 or Proxmox shell).

| Command | Description |
|---------|-------------|
| `qm status 101` | Show VM running state |
| `qm start 101` | Start the VM |
| `qm stop 101` | Hard stop (like pulling power) |
| `qm shutdown 101` | Graceful ACPI shutdown |
| `qm reboot 101` | Graceful ACPI reboot |
| `qm reset 101` | Hard reset (like pressing reset button) |
| `qm suspend 101` | Suspend VM to RAM |
| `qm resume 101` | Resume suspended VM |
| `qm config 101` | Show full VM configuration |
| `qm set 101 -memory 8192` | Change VM memory (requires stop/start) |
| `qm set 101 -cores 4` | Change CPU cores (requires stop/start) |
| `qm snapshot 101 --snapname NAME` | Create a snapshot |
| `qm listsnapshot 101` | List all snapshots |
| `qm rollback 101 --snapname NAME` | Rollback to snapshot (VM must be stopped) |
| `qm delsnapshot 101 --snapname NAME` | Delete a snapshot |
| `qm unlock 101` | Remove VM lock (if stuck) |
| `qm monitor 101` | Enter QEMU monitor (advanced) |
| `qm terminal 101` | Serial terminal (if configured) |
| `qm guest cmd 101 ping` | Guest agent command (if agent installed) |
