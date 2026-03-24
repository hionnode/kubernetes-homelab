# LXC Container with Tailscale for Remote Claude Code Access

Comprehensive guide to deploying an Ubuntu 24.04 LXC container on Proxmox VE 8.x, installing Tailscale for secure overlay networking, and connecting Claude Code as a remote SSH development environment with full access to the Kubernetes homelab LAN.

**Applies to:** Proxmox VE 8.x, Ubuntu 24.04 LTS, Tailscale, OPNsense 25.x, Claude Code CLI

**Related docs:**
- [architecture-diagrams.md](architecture-diagrams.md) — network topology
- [opnsense-guide.md](opnsense-guide.md) — OPNsense troubleshooting (Kea DHCP, Unbound DNS)
- [opnsense-configuration-guide.md](opnsense-configuration-guide.md) — firewall/DHCP config reference

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Download the LXC Template](#3-download-the-lxc-template)
4. [Create the LXC Container](#4-create-the-lxc-container)
5. [Enable TUN Device for Tailscale](#5-enable-tun-device-for-tailscale)
6. [Start and Verify Networking](#6-start-and-verify-networking)
7. [Install Tailscale](#7-install-tailscale)
8. [Connect Claude Code via Tailscale SSH](#8-connect-claude-code-via-tailscale-ssh)
9. [Install Troubleshooting Tools](#9-install-troubleshooting-tools)
10. [OPNsense Debugging from the LXC](#10-opnsense-debugging-from-the-lxc)
11. [OPNsense Configuration for the LXC](#11-opnsense-configuration-for-the-lxc)
12. [Security Considerations](#12-security-considerations)
13. [Troubleshooting](#13-troubleshooting)
14. [Quick Reference Card](#14-quick-reference-card)
15. [Glossary and References](#15-glossary-and-references)

---

## 1. Architecture Overview

### 1.1 What We're Building

An LXC container ([glossary: LXC](#lxc-linux-containers)) on the Proxmox host that acts as a remote development gateway. Tailscale ([glossary: Tailscale](#tailscale)) provides a secure WireGuard ([glossary: WireGuard](#wireguard)) tunnel from your laptop to this container, and Claude Code connects over Tailscale SSH ([glossary: Tailscale SSH](#tailscale-ssh)) to run commands directly on the homelab LAN.

### 1.2 Network Diagram

```
                           INTERNET
                              |
                       Main Router (192.168.1.1)
                              |
                 .------------+-------------.
                 |                           |
          Proxmox Host                 OPNsense WAN
         192.168.1.110                192.168.1.100
                 |                           |
                 |                     [VM 101: OPNsense]
                 |                           |
                 |                    OPNsense LAN
                 |                      10.0.0.1
                 |                           |
     .-----------+-----------.               |
     |           |            |              |
  [VM 100]   [CT 300]     [vmbr1]-----------+--------[TP-Link Switch]
  talos-cp1  tailscale-gw                               10.0.0.2
  10.0.0.10  10.0.0.3                          .--------+--------.
                |                              |        |        |
          .-----+-----.                     CP nodes  Workers  MetalLB
          |           |                    10.0.0.10-12 20-22  50-99
     eth0: vmbr1   eth1: vmbr0
     (LAN)         (WAN)
     10.0.0.3      DHCP
          |
     [Tailscale Daemon]
          |
     WireGuard tunnel (UDP 41641)
     via eth1 → 192.168.1.x → main router → internet
          |
     .------------ Tailnet (100.x.y.z) ------------.
     |                                              |
  tailscale-gw                               Your Laptop
  100.x.y.z                                  100.a.b.c
     |                                              |
  Claude Code  <──── Tailscale SSH ────>  claude ssh homelab-gw
```

### 1.3 Why LXC Instead of a VM?

| Aspect | LXC Container | VM (KVM/QEMU) |
|--------|--------------|----------------|
| RAM usage | ~50-100MB | 512MB-1GB+ |
| Boot time | 1-2 seconds | 30-60 seconds |
| Disk footprint | ~500MB | 2-4GB+ |
| Kernel | Shares host kernel | Runs own kernel |
| Isolation | Namespaces + cgroups ([glossary](#cgroups-control-groups)) | Full hardware virtualization |
| Use case fit | Network toolbox, dev environment | Full OS, custom kernels |

For a network diagnostics gateway that runs SSH, CLI tools, and Tailscale, LXC is the right choice. You don't need kernel isolation — you need fast access to the LAN.

### 1.4 Dual-NIC Design

The container has two network interfaces:

- **eth0 on vmbr1 (LAN)** — Static IP 10.0.0.3/24, gateway 10.0.0.1 (OPNsense). Provides direct Layer 2 access to the entire Kubernetes network. This is how you reach OPNsense, Talos nodes, MetalLB services, and the managed switch.

- **eth1 on vmbr0 (WAN)** — DHCP from the main router (192.168.1.x). Provides a direct path to the internet that bypasses OPNsense. This ensures Tailscale can establish its tunnel even if OPNsense is misconfigured or down. Also gives direct access to Proxmox management (192.168.1.110).

---

## 2. Prerequisites

Before starting, you need:

- [ ] **Proxmox host access** — SSH to `root@192.168.1.110`
- [ ] **Tailscale account** — Free at [login.tailscale.com](https://login.tailscale.com). Supports up to 100 devices on the free tier.
- [ ] **Tailscale on your laptop** — Install from [tailscale.com/download](https://tailscale.com/download). Log in to the same account you'll use for the LXC.
- [ ] **Claude Code CLI** — Install from [docs.anthropic.com](https://docs.anthropic.com/en/docs/claude-code)
- [ ] **OPNsense running** — VM 101 should be up with LAN at 10.0.0.1 (not strictly required, but needed for DNS and gateway)

---

## 3. Download the LXC Template

SSH into the Proxmox host and download the Ubuntu 24.04 container template.

```bash
ssh root@192.168.1.110
```

```bash
# Update the template index from Proxmox's official mirror
# pveam = Proxmox VE Appliance Manager (glossary: pveam)
# This fetches the latest list from http://download.proxmox.com/images/
pveam update

# List available Ubuntu templates
pveam available --section system | grep ubuntu-24

# Download Ubuntu 24.04 to "local" storage
# "local" = /var/lib/vz/ on the Proxmox filesystem
# Templates land in /var/lib/vz/template/cache/
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

> **Note:** The exact template filename may differ. Use the output from `pveam available` to get the current name. Templates are compressed rootfs tarballs ([glossary: rootfs](#pveam-proxmox-ve-appliance-manager)) — not ISOs like you'd use for a VM.

Verify the download:

```bash
ls /var/lib/vz/template/cache/ | grep ubuntu
# Should show: ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

---

## 4. Create the LXC Container

Still on the Proxmox host (`root@192.168.1.110`):

```bash
pct create 300 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname tailscale-gw \
  --memory 1024 \
  --swap 512 \
  --cores 2 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr1,ip=10.0.0.3/24,gw=10.0.0.1 \
  --net1 name=eth1,bridge=vmbr0,ip=dhcp \
  --nameserver "10.0.0.1 1.1.1.1" \
  --searchdomain homelab.local \
  --ostype ubuntu \
  --unprivileged 1 \
  --features nesting=1 \
  --start 0 \
  --password
```

You'll be prompted to set a root password — this is for console login only (Tailscale SSH doesn't use it).

### 4.1 Flag-by-Flag Explanation

| Flag | Value | Why |
|------|-------|-----|
| `300` | Container ID (VMID) | VMs use 100-200 in this homelab; 300+ for containers |
| `local:vztmpl/...` | Template path | The rootfs tarball downloaded in Step 3 |
| `--hostname` | `tailscale-gw` | Visible in `pct list`, Tailscale, and the shell prompt |
| `--memory` | `1024` | 1GB RAM. Tailscale + CLI tools use ~200MB; headroom for tcpdump captures and large log analysis |
| `--swap` | `512` | 512MB swap. Safety net for memory spikes |
| `--cores` | `2` | 2 vCPUs. Sufficient for SSH sessions + diagnostics |
| `--rootfs` | `local-lvm:8` | 8GB disk on LVM thin pool. Ubuntu base (~500MB) + tools + logs |
| `--net0` | `name=eth0,bridge=vmbr1,ip=10.0.0.3/24,gw=10.0.0.1` | **LAN NIC**. Static IP in the reserved infrastructure range (10.0.0.2-9). Gateway is OPNsense for LAN routing and NAT to internet. |
| `--net1` | `name=eth1,bridge=vmbr0,ip=dhcp` | **WAN NIC**. Gets DHCP from the main router (192.168.1.x). Direct internet access, bypasses OPNsense. |
| `--nameserver` | `10.0.0.1 1.1.1.1` | Primary DNS: OPNsense Unbound. Fallback: Cloudflare (in case Unbound is down) |
| `--ostype` | `ubuntu` | Tells Proxmox how to configure the container's init system |
| `--unprivileged` | `1` | Runs with user namespace mapping ([glossary: unprivileged containers](#unprivileged-containers)). More secure. |
| `--features` | `nesting=1` | Allows nested container operations. Required for Tailscale's network namespace usage. |
| `--password` | (prompted) | Root password for `pct enter` console access |

### 4.2 Unprivileged vs Privileged — Which and Why?

We use **unprivileged** (recommended):

| Property | Unprivileged | Privileged |
|----------|-------------|------------|
| Root inside container | Mapped to host UID 100000+ | Real root (UID 0) on host |
| Container escape risk | Attacker gets unprivileged host user | Attacker gets root on host |
| Device access | Explicitly allowlisted via cgroups | Broader device access |
| Performance | Negligible overhead from UID mapping | Slightly faster filesystem ops |
| When to use | Almost always (including this guide) | Raw disk access, NFS server, nested Docker |

Unprivileged containers use Linux user namespaces ([glossary: namespaces](#namespaces-linux)) to map UID 0 inside the container to a high, non-root UID on the host. If something goes wrong, the blast radius is contained.

### 4.3 Verify the Container Config

```bash
pct config 300
```

You should see the settings you specified. The full config file lives at `/etc/pve/lxc/300.conf`.

---

## 5. Enable TUN Device for Tailscale

Tailscale needs the TUN device ([glossary: TUN/TAP](#tuntap-devices)) to create its WireGuard tunnel. Unprivileged containers don't have TUN access by default — we need to grant it.

Run on the Proxmox host:

```bash
# Allow the TUN/TAP character device (major 10, minor 200)
# in the container's cgroup2 device allowlist
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> /etc/pve/lxc/300.conf

# Bind-mount the host's /dev/net/tun into the container
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> /etc/pve/lxc/300.conf
```

### 5.1 What These Lines Do

**`lxc.cgroup2.devices.allow: c 10:200 rwm`**

The Linux kernel uses cgroups ([glossary: cgroups](#cgroups-control-groups)) to control which devices a container can access. `c 10:200` identifies the TUN device by its major:minor numbers (10 = misc devices, 200 = TUN/TAP). `rwm` = read, write, mknod permissions.

Without this line, any attempt to open `/dev/net/tun` inside the container gets `EPERM` (Operation not permitted).

**`lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file`**

This bind-mounts the host's `/dev/net/tun` device node into the container's filesystem. The `create=file` flag creates the mount target (`/dev/net/tun`) inside the container if it doesn't exist. Without this, the device file simply doesn't appear in the container's `/dev/net/` directory.

### 5.2 Verify the Config

```bash
cat /etc/pve/lxc/300.conf
```

You should see both `lxc.cgroup2` and `lxc.mount.entry` lines at the bottom of the file.

---

## 6. Start and Verify Networking

### 6.1 Start the Container

```bash
pct start 300
```

### 6.2 Enter the Container

```bash
pct enter 300
```

You're now inside the container as root. The prompt should show `root@tailscale-gw`.

### 6.3 Verify Network Interfaces

```bash
# Show all interfaces and IPs
ip addr show
```

Expected output:
- `eth0`: 10.0.0.3/24 (LAN)
- `eth1`: 192.168.1.x/24 (WAN, from DHCP)
- `lo`: 127.0.0.1 (loopback)

### 6.4 Test Connectivity

```bash
# Test LAN gateway (OPNsense)
ping -c 3 10.0.0.1

# Test WAN gateway (main router)
ping -c 3 192.168.1.1

# Test internet
ping -c 3 8.8.8.8

# Test DNS resolution (via OPNsense Unbound)
apt update  # This also serves as a DNS + internet test
```

### 6.5 Check Routing

```bash
ip route show
```

Expected:
```
default via 10.0.0.1 dev eth0       # Primary: LAN through OPNsense
10.0.0.0/24 dev eth0 scope link     # LAN subnet
192.168.1.0/24 dev eth1 scope link  # WAN subnet
```

If you see two default routes (both eth0 and eth1), set eth0 as primary:

```bash
# Remove eth1 default route and re-add with higher metric (lower priority)
ip route del default via 192.168.1.1 dev eth1 2>/dev/null
ip route add default via 192.168.1.1 dev eth1 metric 200
```

> **Why this routing matters:** The default route via OPNsense (10.0.0.1) ensures all traffic goes through the firewall's NAT — same path as every other LAN device. The eth1 WAN route is a backup. If OPNsense goes down, you can switch the default route to eth1 and still have internet access for Tailscale.

### 6.6 Verify TUN Device

```bash
ls -la /dev/net/tun
# Expected: crw-rw-rw- 1 root root 10, 200 ...
```

If this file doesn't exist, go back to [Step 5](#5-enable-tun-device-for-tailscale) and verify the config lines were added correctly. You may need to stop and start the container (`pct stop 300 && pct start 300` from the Proxmox host) for config changes to take effect.

---

## 7. Install Tailscale

All commands in this section run **inside the container** (`pct enter 300`).

### 7.1 Install Tailscale from Official Repository

```bash
# Install prerequisites
apt update && apt install -y curl gnupg

# Add Tailscale's GPG key
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | \
  tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

# Add Tailscale's apt repository
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | \
  tee /etc/apt/sources.list.d/tailscale.list

# Install Tailscale
apt update && apt install -y tailscale

# Enable and start the Tailscale daemon
systemctl enable --now tailscaled
```

### 7.2 Authenticate and Enable SSH

```bash
# Bring Tailscale up with SSH access enabled
tailscale up --ssh --hostname=homelab-gw
```

This prints a URL like:

```
To authenticate, visit:
  https://login.tailscale.com/a/xxxxxxxxxxxx
```

Open that URL in your browser, log into your Tailscale account, and approve the device. After approval, the terminal will show "Success."

### 7.3 Using an Auth Key (Headless / Automated)

If you prefer not to open a browser (or are automating this):

1. Go to [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
2. Click **Generate auth key**
3. Choose:
   - **Reusable**: Can be used for multiple devices
   - **Ephemeral**: Device auto-removes when it disconnects (good for testing)
   - **Pre-approved**: Skips admin approval step

```bash
# Use the auth key — no browser needed
tailscale up --ssh --hostname=homelab-gw --authkey=tskey-auth-XXXXXXXXXXXXX
```

### 7.4 Verify Tailscale Status

```bash
# Check status — shows your Tailnet devices
tailscale status

# Get this container's Tailscale IP
tailscale ip -4
# Output: 100.x.y.z (from the CGNAT range)

# Check if SSH is enabled
tailscale debug ssh
```

### 7.5 Enable MagicDNS

MagicDNS ([glossary: MagicDNS](#magicdns)) assigns human-readable names to Tailnet devices. With it enabled, you can use `homelab-gw` instead of `100.x.y.z`.

1. Go to [login.tailscale.com/admin/dns](https://login.tailscale.com/admin/dns)
2. Enable **MagicDNS** if not already on
3. Your container is now reachable at `homelab-gw.<tailnet-name>.ts.net`

The short name `homelab-gw` works from any device on the same Tailnet.

### 7.6 How Tailscale SSH Works

Traditional SSH requires managing key pairs — generating keys, copying public keys to `~/.ssh/authorized_keys`, dealing with key rotation. Tailscale SSH replaces all of this:

1. You run `tailscale up --ssh` on the server (our LXC container)
2. The Tailscale daemon on the server starts accepting SSH connections authenticated by **Tailscale identity**, not SSH keys
3. When you run `ssh root@homelab-gw` from your laptop, the Tailscale client intercepts the connection
4. Both sides present their WireGuard identities (tied to your Tailscale account)
5. The Tailscale coordination server verifies both nodes belong to the same Tailnet ([glossary: Tailnet](#tailnet))
6. An encrypted WireGuard tunnel carries the SSH session — no passwords, no keys, no `authorized_keys` files
7. Access control is managed centrally via Tailscale ACLs, not per-machine SSH configs

```
Traditional SSH:                    Tailscale SSH:

  [Laptop]                            [Laptop]
     |                                    |
  ssh-keygen                         tailscale login
  ssh-copy-id                        (identity = your account)
     |                                    |
  ~/.ssh/id_ed25519 ──────>          WireGuard identity ──────>
     |                                    |
  [Server]                            [Server]
  ~/.ssh/authorized_keys             tailscale up --ssh
  /etc/ssh/sshd_config               (no SSH config needed)
```

---

## 8. Connect Claude Code via Tailscale SSH

### 8.1 From Your Laptop — Verify Tailscale Connectivity

Make sure your laptop is on the same Tailnet:

```bash
# Check Tailscale is running on your laptop
tailscale status
# Should list "homelab-gw" as a peer

# Test connectivity
tailscale ping homelab-gw

# Test SSH directly (should work without keys)
ssh root@homelab-gw
# Type 'exit' to disconnect
```

### 8.2 Connect Claude Code

```bash
# Launch Claude Code with its execution context on the remote LXC
claude ssh homelab-gw
```

Claude Code now runs locally on your laptop (UI, LLM interaction) but executes **all file operations, shell commands, and tool calls on the remote LXC container** over the Tailscale SSH tunnel.

### 8.3 Verify LAN Access from Claude Code

Once connected, verify Claude Code can reach the homelab infrastructure:

```bash
# From within the Claude Code session (running on tailscale-gw):

# Reach OPNsense gateway
ping -c 1 10.0.0.1

# Reach Proxmox management
ping -c 1 192.168.1.110

# Test DNS via OPNsense
dig google.com @10.0.0.1

# SSH to OPNsense (if SSH is enabled there)
ssh root@10.0.0.1 "configctl kea status"
```

Claude Code now has the same network access as any device on the 10.0.0.0/24 LAN — it can SSH into OPNsense, query Kea DHCP, check Unbound DNS, run `kubectl`, and execute any diagnostic script.

---

## 9. Install Troubleshooting Tools

Inside the LXC container:

```bash
apt update && apt install -y \
  socat \
  dnsutils \
  nmap \
  tcpdump \
  jq \
  curl \
  wget \
  iputils-ping \
  net-tools \
  iproute2 \
  openssh-client \
  traceroute \
  mtr \
  vim \
  git \
  tmux \
  htop
```

### 9.1 Tool Reference

| Tool | Package | What It's For |
|------|---------|---------------|
| `socat` | socat | Multipurpose relay — test TCP/UDP connections, interact with Unix sockets (e.g., Kea control socket) |
| `dig` / `nslookup` | dnsutils | DNS query tools — test OPNsense Unbound resolution |
| `nmap` | nmap | Port scanning, network discovery, DHCP broadcast testing |
| `tcpdump` | tcpdump | Packet capture — see actual DHCP, DNS, ARP traffic on the wire |
| `jq` | jq | JSON parser — essential for reading Kea DHCP config (JSON format) |
| `curl` | curl | HTTP client — query OPNsense API |
| `mtr` | mtr | Combined ping + traceroute — diagnose routing issues |
| `tmux` | tmux | Terminal multiplexer — run multiple diagnostic sessions in one SSH connection |

### 9.2 Install kubectl and talosctl (Optional)

```bash
# kubectl — Kubernetes CLI
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/

# talosctl — Talos Linux CLI
curl -sL https://talos.dev/install | sh
```

### 9.3 Clone the Homelab Repo

```bash
git clone https://github.com/hionnode/kubernetes-homelab.git /root/kubernetes-homelab
```

This puts the diagnostic scripts (`collect-opnsense-logs.sh`, `diag-health-check.sh`, etc.) on the LXC for direct use.

---

## 10. OPNsense Debugging from the LXC

### 10.1 SSH to OPNsense

```bash
# First time — set up passwordless SSH
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id root@10.0.0.1

# Now SSH without password
ssh root@10.0.0.1
```

### 10.2 Kea DHCP Debugging

```bash
# === Run these ON OPNsense (ssh root@10.0.0.1) ===

# Check if Kea is running
configctl kea status

# Which process owns DHCP port 67?
sockstat -4 -l | grep :67
# Expected: kea-dhcp4 (NOT dhcpd — that's the old ISC DHCP)

# View Kea configuration (JSON)
cat /usr/local/etc/kea/kea-dhcp4.conf | jq .

# Check reservations — look for hw-address format (must be lowercase)
grep -i hw-address /usr/local/etc/kea/kea-dhcp4.conf

# View current leases
cat /var/lib/kea/kea-leases4.csv

# Check for declined leases (state=2) blocking reservations
grep ",2," /var/lib/kea/kea-leases4.csv

# Delete a stale declined lease via control socket
echo '{"command": "lease4-del", "arguments": {"ip-address": "10.0.0.2"}}' | \
  socat UNIX:/var/run/kea/kea4-ctrl-socket.sock -

# Watch Kea logs in real-time
tail -f /var/log/system/latest.log | grep -i kea

# Restart Kea
configctl kea restart
```

```bash
# === Run these FROM the LXC (not on OPNsense) ===

# Test DHCP server response
nmap --script broadcast-dhcp-discover -e eth0

# Run the log collection script
cd /root/kubernetes-homelab/scripts
./collect-opnsense-logs.sh 10.0.0.1
# Output lands in logs/opnsense-<timestamp>/
```

### 10.3 Unbound DNS Debugging

```bash
# === On OPNsense (ssh root@10.0.0.1) ===

# Check if Unbound is running
service unbound status

# But ALSO check sockstat — service status can lie (PID file mismatch)
sockstat -4 -l | grep :53
# If unbound is listed here, it IS running despite what service says

# Fix PID mismatch if needed
pgrep -f "/var/unbound/unbound.conf" > /var/run/unbound.pid

# Validate config
unbound-checkconf /var/unbound/unbound.conf

# Check logs
grep -i unbound /var/log/system/latest.log | tail -30
```

```bash
# === From the LXC ===

# Test DNS via OPNsense
dig google.com @10.0.0.1

# Test local hostname resolution
dig tailscale-gw.homelab.local @10.0.0.1

# Test DNSSEC
dig +dnssec google.com @10.0.0.1

# Compare OPNsense DNS vs public DNS
dig google.com @10.0.0.1 +short
dig google.com @8.8.8.8 +short

# Full DNS test matrix
cd /root/kubernetes-homelab/scripts
./diag-dns-matrix.sh
```

### 10.4 OPNsense API Access

```bash
# From the LXC — query OPNsense API
# Replace KEY:SECRET with your OPNsense API credentials

# Get firmware status
curl -k -u "KEY:SECRET" https://10.0.0.1/api/core/firmware/status | jq .

# Get DHCP leases
curl -k -u "KEY:SECRET" https://10.0.0.1/api/kea/leases4/searchLease | jq .

# Get Unbound status
curl -k -u "KEY:SECRET" https://10.0.0.1/api/unbound/service/status | jq .

# Get firewall rules
curl -k -u "KEY:SECRET" https://10.0.0.1/api/firewall/filter/searchRule | jq .
```

---

## 11. OPNsense Configuration for the LXC

### 11.1 Add Kea DHCP Reservation

Even though the LXC uses a static IP (set in the Proxmox container config), a DHCP reservation prevents IP conflicts.

First, find the LXC's MAC address:

```bash
# On the Proxmox host
grep hwaddr /etc/pve/lxc/300.conf | head -1
# Output: net0: name=eth0,...,hwaddr=XX:XX:XX:XX:XX:XX,...
```

In OPNsense WebGUI (`https://10.0.0.1`):

1. **Services → Kea DHCP → Reservations**
2. Click **+** to add:

| Field | Value |
|-------|-------|
| IP Address | 10.0.0.3 |
| MAC Address | (the hwaddr from above, **lowercase**) |
| Hostname | tailscale-gw |
| Description | Tailscale gateway LXC for remote access |

3. **Save → Apply Changes**

### 11.2 Add DNS Host Override

1. **Services → Unbound DNS → Host Overrides**
2. Click **+** to add:

| Field | Value |
|-------|-------|
| Host | tailscale-gw |
| Domain | homelab.local |
| IP | 10.0.0.3 |
| Description | Tailscale gateway LXC |

3. **Save → Apply Changes**

Test from any LAN device: `dig tailscale-gw.homelab.local @10.0.0.1`

### 11.3 Verify Firewall Rules

The default OPNsense LAN rule allows all LAN traffic. Verify:

1. **Firewall → Rules → LAN**
2. Confirm a rule exists with:
   - Action: **Pass**
   - Source: **LAN net** (10.0.0.0/24)
   - Destination: **any**

Since 10.0.0.3 is within 10.0.0.0/24, it's automatically covered. No additional rules needed.

---

## 12. Security Considerations

### 12.1 Tailscale ACLs

Tailscale ACLs ([glossary: Tailscale ACLs](#tailscale-acls)) control which devices can communicate. Configure at [login.tailscale.com/admin/acls](https://login.tailscale.com/admin/acls).

Recommended policy:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:homelab:*"]
    }
  ],
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:homelab"],
      "users": ["root", "autogroup:nonroot"]
    }
  ],
  "tagOwners": {
    "tag:homelab": ["autogroup:admin"]
  }
}
```

- `autogroup:member` = all authenticated users in your Tailnet
- `tag:homelab` = machines tagged as homelab infrastructure
- The SSH section controls who can SSH and as which user

To tag the LXC:

```bash
tailscale up --ssh --hostname=homelab-gw --advertise-tags=tag:homelab
```

### 12.2 Container Isolation

The LXC container has these isolation properties:

- **User namespace** — Root inside = UID 100000+ on host (not real root)
- **Network namespace** — Own network stack, cannot see host interfaces
- **PID namespace** — Own process tree, cannot see host processes
- **Mount namespace** — Own filesystem view, limited host mounts
- **cgroup limits** — Cannot exceed 1GB RAM, 2 cores
- **TUN access** — Narrowly scoped to device 10:200 only

### 12.3 Blast Radius Awareness

The LXC has full access to the 10.0.0.0/24 LAN. If it's compromised, an attacker can reach:
- OPNsense management (10.0.0.1)
- All Kubernetes nodes (10.0.0.10-22)
- The managed switch (10.0.0.2)

This is by design for a management bastion. Mitigations:
- Keep the container updated (`apt upgrade`)
- Use Tailscale ACLs to restrict who can connect
- The Tailscale SSH identity layer means compromising the container alone isn't enough — you also need a valid Tailscale identity

### 12.4 Hardening

```bash
# Inside the LXC:

# Enable automatic security updates
apt install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# If running OpenSSH alongside Tailscale SSH (for LAN access):
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

---

## 13. Troubleshooting

| Problem | Diagnosis | Fix |
|---------|-----------|-----|
| **Tailscale won't start** | `journalctl -u tailscaled -n 50` | Check TUN device: `ls -la /dev/net/tun`. If missing, verify `/etc/pve/lxc/300.conf` has cgroup2 and mount entries. Stop/start container. |
| **No internet from LXC** | `ping 8.8.8.8` fails | Check `ip route show default`. Verify OPNsense is running and NAT works. Check eth1 has DHCP lease: `ip addr show eth1`. |
| **Can't reach OPNsense** | `ping 10.0.0.1` fails | Verify eth0 has 10.0.0.3: `ip addr show eth0`. Check OPNsense LAN interface is up. Check vmbr1 bridge on Proxmox host. |
| **Tailscale SSH rejected** | `ssh root@homelab-gw` hangs or is refused | Run `tailscale status` on both sides. Re-auth: `tailscale up --ssh --hostname=homelab-gw`. Check ACLs at login.tailscale.com. |
| **DNS not resolving** | `dig google.com @10.0.0.1` fails | Try `dig google.com @8.8.8.8`. If that works, OPNsense Unbound is the issue — see [opnsense-guide.md Section 8.6](opnsense-guide.md#86-unbound-dns-not-running-despite-correct-configuration). |
| **Claude Code SSH hangs** | Connection times out | `tailscale ping homelab-gw` from laptop. If DERP relay: check for corporate firewall blocking UDP 41641. Try `tailscale up --netfilter-mode=off` on restricted networks. |
| **Container won't start** | `pct start 300` error | Check LVM free space: `lvs`. Check config: `pct config 300`. Common: template file missing (re-download). |
| **eth1 no DHCP lease** | `ip addr show eth1` shows no IP | Check vmbr0 bridge exists: `brctl show` on Proxmox. Check main router DHCP is running. |
| **Tailscale userspace mode slow** | High latency on tunnel | Expected in LXC (no kernel WireGuard module). Performance is still fine for SSH/CLI. Kernel mode requires privileged container. |

---

## 14. Quick Reference Card

```
╔══════════════════════════════════════════════════════════════╗
║                    LXC Quick Reference                       ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Container ID:    300                                        ║
║  Hostname:        tailscale-gw                               ║
║  OS:              Ubuntu 24.04 LTS                           ║
║  Resources:       1GB RAM, 2 cores, 8GB disk                 ║
║  LAN IP:          10.0.0.3/24 (eth0, vmbr1)                  ║
║  WAN IP:          DHCP (eth1, vmbr0)                          ║
║  Tailscale IP:    100.x.y.z (run: tailscale ip -4)           ║
║  MagicDNS:        homelab-gw.<tailnet>.ts.net                ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  ACCESS                                                      ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Tailscale SSH:   ssh root@homelab-gw                        ║
║  Claude Code:     claude ssh homelab-gw                      ║
║  Proxmox CLI:     pct enter 300                              ║
║  Proxmox WebGUI:  Datacenter → Node → CT 300 → Console      ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  MANAGEMENT (from Proxmox host)                              ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  pct start 300           Start container                     ║
║  pct stop 300            Stop container                      ║
║  pct enter 300           Shell into container                ║
║  pct config 300          View config                         ║
║  pct status 300          Check status                        ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  FROM INSIDE THE LXC                                         ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  tailscale status        Check Tailscale peers               ║
║  ping 10.0.0.1           Test OPNsense                       ║
║  ssh root@10.0.0.1       SSH to OPNsense                     ║
║  dig google.com @10.0.0.1  Test DNS                          ║
║  ./scripts/collect-opnsense-logs.sh  Collect debug data      ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  UPDATED IP ALLOCATION (10.0.0.0/24)                         ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  10.0.0.1       OPNsense Gateway / DHCP / DNS                ║
║  10.0.0.2       TP-Link SG2008 managed switch                ║
║  10.0.0.3       tailscale-gw LXC (CT 300)     ← NEW         ║
║  10.0.0.4-9     Reserved (future infrastructure)             ║
║  10.0.0.5       Kubernetes API VIP (floating)                ║
║  10.0.0.10-12   Control Planes (1 VM + 2 physical)           ║
║  10.0.0.20-22   Workers (3 physical)                         ║
║  10.0.0.50-99   MetalLB LoadBalancer pool                    ║
║  10.0.0.100-200 DHCP dynamic pool                            ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

---

## 15. Glossary and References

### LXC (Linux Containers)

A lightweight OS-level virtualization technology built into the Linux kernel. Unlike VMs (which emulate hardware and run a separate kernel), LXC containers share the host kernel and use kernel namespaces and cgroups to isolate processes. Each container has its own root filesystem, network stack, process tree, and user space, but system calls go directly to the host kernel. This makes containers significantly faster to start (~1 second) and more resource-efficient than VMs.

- [linuxcontainers.org/lxc](https://linuxcontainers.org/lxc/) — Official LXC project
- [pve.proxmox.com/wiki/Linux_Container](https://pve.proxmox.com/wiki/Linux_Container) — Proxmox LXC documentation

### cgroups (Control Groups)

A Linux kernel feature that limits, accounts for, and isolates resource usage (CPU, memory, disk I/O, network) of process groups. Proxmox uses cgroups v2 to enforce the `--memory 1024` and `--cores 2` limits set during `pct create`. cgroups also control device access — the `lxc.cgroup2.devices.allow: c 10:200 rwm` line grants TUN device access to the container.

When you set `--memory 1024`, Proxmox writes `memory.max = 1073741824` to the container's cgroup. If the container tries to use more, the OOM killer terminates processes inside the container (not on the host).

- [kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) — Kernel cgroup v2 docs

### Namespaces (Linux)

A kernel feature that partitions kernel resources so different processes see different views of the system. There are 8 types:

| Namespace | Isolates | Example |
|-----------|----------|---------|
| PID | Process IDs | Container's `ps aux` only shows its own processes |
| NET | Network stack | Container has its own interfaces, routing table, iptables |
| MNT | Mount points | Container has its own filesystem tree |
| UTS | Hostname | Container can set its own hostname (`tailscale-gw`) |
| IPC | IPC resources | Shared memory, message queues are isolated |
| USER | UID/GID mapping | Root (UID 0) inside maps to UID 100000 on host |
| CGROUP | cgroup hierarchy | Container sees only its own cgroup |
| TIME | System clock | Container can have its own clock offset |

LXC uses all of these. The USER namespace is what makes "unprivileged containers" possible.

- [man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html) — Linux namespaces reference

### PCT (Proxmox Container Toolkit)

The command-line tool for managing LXC containers on Proxmox VE. Key commands: `pct create`, `pct start/stop/destroy`, `pct enter` (attach shell), `pct config` (view config), `pct set` (modify config). Container configs live at `/etc/pve/lxc/<vmid>.conf` and are synced across cluster nodes via Proxmox's pmxcfs filesystem.

- [pve.proxmox.com/pve-docs/pct.1.html](https://pve.proxmox.com/pve-docs/pct.1.html) — PCT man page

### pveam (Proxmox VE Appliance Manager)

CLI tool for downloading container templates — pre-built OS rootfs tarballs — from Proxmox's official mirror. Templates are stored in `/var/lib/vz/template/cache/`. The `pveam update` command refreshes the index from `http://download.proxmox.com/images/`. Templates are compressed with zstd (`.tar.zst`) — they are NOT ISOs.

A "rootfs tarball" is a compressed archive of a minimal Linux installation's root filesystem (`/bin`, `/etc`, `/usr`, etc.) — everything needed to boot a container without a kernel or bootloader.

- [pve.proxmox.com/pve-docs/pveam.1.html](https://pve.proxmox.com/pve-docs/pveam.1.html) — pveam man page
- [download.proxmox.com/images/system/](http://download.proxmox.com/images/system/) — Template mirror

### Tailscale

A zero-config mesh VPN built on WireGuard. Creates a peer-to-peer encrypted network (called a Tailnet) between your devices. Unlike traditional VPNs that route all traffic through a central server, Tailscale establishes **direct** WireGuard tunnels between devices whenever possible.

A coordination server (hosted by Tailscale at `login.tailscale.com`) handles key exchange and NAT traversal, but **never sees your traffic** — all data goes directly between devices. Each device gets a stable 100.x.y.z IP address from the CGNAT range (100.64.0.0/10).

- [tailscale.com/kb/1151/what-is-tailscale](https://tailscale.com/kb/1151/what-is-tailscale) — What is Tailscale?
- [tailscale.com/blog/how-tailscale-works](https://tailscale.com/blog/how-tailscale-works) — Deep dive: How Tailscale Works

### Tailscale SSH

Tailscale's built-in SSH server that replaces traditional OpenSSH key-based authentication with Tailscale identity-based authentication. When enabled (`tailscale up --ssh`), the Tailscale daemon acts as an SSH server that authenticates connecting clients based on their Tailscale identity — no SSH keys, no passwords, no `authorized_keys` files.

Access control is managed centrally via Tailscale ACLs (who can SSH, as which user) instead of per-machine SSH configuration.

- [tailscale.com/kb/1193/tailscale-ssh](https://tailscale.com/kb/1193/tailscale-ssh) — Tailscale SSH docs

### Tailscale ACLs

Tailscale Access Control Lists define which devices and users can communicate within your Tailnet. Configured as JSON at `login.tailscale.com/admin/acls`. ACLs are default-deny — if no rule matches, traffic is blocked.

Key concepts:
- **Tags** (`tag:homelab`) — Group machines by purpose
- **Autogroups** (`autogroup:member`) — Built-in groups like "all users"
- **SSH rules** — Separate section controlling who can SSH where, as which user

- [tailscale.com/kb/1018/acls](https://tailscale.com/kb/1018/acls) — ACL configuration guide

### WireGuard

A modern VPN protocol built into the Linux kernel (since 5.6). Uses Curve25519 for key exchange, ChaCha20-Poly1305 for authenticated encryption, and BLAKE2s for hashing. WireGuard is ~4,000 lines of code vs ~100,000+ for OpenVPN/IPsec.

Tailscale uses WireGuard as its data plane — all Tailscale traffic is WireGuard-encrypted. In LXC containers (without kernel module access), Tailscale uses `wireguard-go`, a userspace implementation that reads/writes through the TUN device.

- [wireguard.com](https://www.wireguard.com/) — Official WireGuard site
- [wireguard.com/papers/wireguard.pdf](https://www.wireguard.com/papers/wireguard.pdf) — WireGuard whitepaper

### DERP (Designated Encrypted Relay for Packets)

Tailscale's relay servers, used as a fallback when direct peer-to-peer WireGuard connections are impossible (e.g., both peers behind symmetric NAT). DERP relays see only WireGuard-encrypted packets — they **cannot decrypt** the contents.

Tailscale operates DERP servers globally. You can check whether your connection is direct or relayed with `tailscale status` — it shows "direct" or "relay: xxx" for each peer.

In this homelab setup, traffic will likely go direct since the LXC has internet access via vmbr0. DERP is the automatic fallback if direct connection fails.

- [tailscale.com/kb/1232/derp-servers](https://tailscale.com/kb/1232/derp-servers) — DERP server documentation
- [tailscale.com/blog/how-tailscale-works](https://tailscale.com/blog/how-tailscale-works) — See "What if NAT traversal fails?"

### MagicDNS

Tailscale's built-in DNS that automatically assigns DNS names to Tailnet devices. Each device is reachable at `<hostname>.<tailnet-name>.ts.net`. MagicDNS intercepts DNS queries for `.ts.net` domains and resolves them locally on the Tailscale daemon — no external DNS servers involved.

This means you can `ssh root@homelab-gw` instead of remembering `100.x.y.z`.

- [tailscale.com/kb/1081/magicdns](https://tailscale.com/kb/1081/magicdns) — MagicDNS setup

### Tailnet

The private network created by Tailscale for your account. All devices authenticated to the same Tailscale account (or organization) form a single Tailnet. Devices communicate directly (peer-to-peer WireGuard) without port forwarding, firewall rules, or VPN concentrators.

Your Tailnet is identified by a domain suffix — `<your-email>.ts.net` for personal accounts or `<org-name>.ts.net` for organizations.

- [tailscale.com/kb/1136/tailnet](https://tailscale.com/kb/1136/tailnet) — What is a Tailnet?

### NAT Traversal

Techniques for establishing direct connections between devices behind NAT routers. Most home/office networks use NAT — devices have private IPs (192.168.x.x, 10.x.x.x) that are translated to a single public IP at the router.

The problem: two devices behind different NAT routers can't directly reach each other (neither knows the other's public IP:port mapping). NAT traversal solves this using techniques like STUN, hole punching, and UPnP.

Tailscale implements aggressive NAT traversal — it succeeds in establishing direct connections ~92% of the time. For the other ~8%, it falls back to DERP relays.

- [tailscale.com/blog/how-nat-traversal-works](https://tailscale.com/blog/how-nat-traversal-works) — Excellent deep dive by Tailscale

### STUN (Session Traversal Utilities for NAT)

A protocol (RFC 5389) that helps a client discover its public IP address and the type of NAT it's behind. A STUN server sits on the public internet; the client sends a request, and the server responds with the client's public IP:port as seen from outside the NAT.

Tailscale uses STUN to discover each device's NAT mapping, then uses this information to "punch holes" — establish direct WireGuard connections between peers.

- [datatracker.ietf.org/doc/html/rfc5389](https://datatracker.ietf.org/doc/html/rfc5389) — STUN RFC

### TURN (Traversal Using Relays around NAT)

A protocol (RFC 5766) that relays traffic when direct NAT traversal fails. Unlike STUN (which only helps discover NAT mappings), TURN actually relays packets through a server. Tailscale's DERP servers serve a similar purpose but use a custom protocol over HTTPS instead of standard TURN.

- [datatracker.ietf.org/doc/html/rfc5766](https://datatracker.ietf.org/doc/html/rfc5766) — TURN RFC

### Unprivileged Containers

LXC containers that use Linux user namespaces to map container UIDs to high-range host UIDs. Root (UID 0) inside the container is mapped to an unprivileged UID on the host (typically 100000). This means even if a process escapes the container namespace, it has no root privileges on the host.

Proxmox enables this with `--unprivileged 1`. The UID mapping is stored in `/etc/pve/lxc/<vmid>.conf` as `lxc.idmap` entries:
```
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 65536
```
This maps container UIDs 0-65535 to host UIDs 100000-165535.

- [pve.proxmox.com/wiki/Unprivileged_LXC_containers](https://pve.proxmox.com/wiki/Unprivileged_LXC_containers) — Proxmox docs
- [man7.org/linux/man-pages/man7/user_namespaces.7.html](https://man7.org/linux/man-pages/man7/user_namespaces.7.html) — User namespace reference

### TUN/TAP Devices

Virtual network interfaces in the Linux kernel:
- **TUN** (network **TUN**nel) — Operates at Layer 3 (IP packets). VPN software writes IP packets to the TUN device; the kernel routes them.
- **TAP** — Operates at Layer 2 (Ethernet frames). Used for bridging.

WireGuard (and Tailscale's `wireguard-go`) creates a TUN device to send/receive encrypted IP packets. The device node is `/dev/net/tun` with major number 10, minor number 200.

In unprivileged LXC containers, access to `/dev/net/tun` must be explicitly granted via both:
1. cgroup device allowlist (`lxc.cgroup2.devices.allow`)
2. Bind mount (`lxc.mount.entry`)

- [kernel.org/doc/html/latest/networking/tuntap.html](https://www.kernel.org/doc/html/latest/networking/tuntap.html) — Kernel TUN/TAP docs

### Claude Code SSH Remote Connections

Claude Code (Anthropic's CLI for Claude AI) supports running on remote machines via SSH. When you run `claude ssh <host>`, Claude Code establishes an SSH session to the target and executes all operations (file reads, writes, shell commands, tool calls) on the remote machine. The Claude Code UI runs locally on your laptop, but its "execution context" is the remote filesystem and shell.

Combined with Tailscale SSH, this provides secure, identity-based remote access without SSH key management — your Tailscale account IS the credential.

- [docs.anthropic.com/en/docs/claude-code](https://docs.anthropic.com/en/docs/claude-code) — Claude Code documentation
