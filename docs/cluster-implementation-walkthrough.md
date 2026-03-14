# Cluster Implementation Walkthrough

**Date:** 2026-03-14
**Purpose:** Step-by-step hands-on guide to bring the Talos Kubernetes homelab from its current broken state to a fully operational 6-node cluster with platform services.
**Scope:** All 6 phases from the [gap analysis](talos-current-vs-planned.md) action plan, with exact commands, UI paths, verification steps, and decision points.

---

> **How to use this guide**
>
> This guide is designed to be followed sequentially — each phase builds on the previous one. You cannot skip phases unless explicitly noted.
>
> - **Checkpoints** at the end of each phase confirm everything works before moving on.
> - **Decision Points** (marked with a table) require you to choose between options. Each includes a recommendation.
> - Commands assume you are running from your **workstation** (macOS) unless prefixed with `ssh root@10.0.0.3`.
> - All Proxmox references use `10.0.0.3:8006` (the current Proxmox host IP).

---

## Table of Contents

1. [Current State Summary](#1-current-state-summary)
2. [Phase A — Fix Networking](#2-phase-a--fix-networking)
3. [Phase B — Get CP1 Operational](#3-phase-b--get-cp1-operational)
4. [Phase C — Bootstrap Cluster](#4-phase-c--bootstrap-cluster)
5. [Phase D — Network Hardening / VLAN](#5-phase-d--network-hardening--vlan)
6. [Phase E — Scale to Full Cluster](#6-phase-e--scale-to-full-cluster)
7. [Phase F — Platform Services](#7-phase-f--platform-services)
8. [Decisions Reference](#8-decisions-reference)
9. [Troubleshooting Quick Reference](#9-troubleshooting-quick-reference)
10. [Network Quick Reference](#10-network-quick-reference)
11. [References](#11-references)

---

## 1. Current State Summary

### Network Diagram

```
                          INTERNET
                              |
                    [Main Router: 192.168.1.1]
                              |
                    WAN: 192.168.1.0/24
                              |
            ┌─────────────────┴──────────────────┐
            │         Proxmox Host               │
            │         10.0.0.3                   │
            │                                    │
            │  vmbr0 (WAN bridge)                │
            │  ├── enp2s0 (physical WAN NIC)     │
            │  └── tap101i0 ─── VM 101 net0      │
            │                       │            │
            │                  [OPNsense]        │
            │              VM 101 / home-router  │
            │              WAN: 192.168.1.101    │
            │              LAN: 10.0.0.1 (×)     │
            │                       │            │
            │  vmbr1 (LAN bridge)   │            │
            │  ├── tap101i1 ─── VM 101 net1      │
            │  └── fwpr100p0 ─── VM 100          │
            │       │               │            │
            │  [Talos CP1]          │            │
            │  VM 100 / talos-cp-1  │            │
            │  10.0.0.10 (×)        │            │
            │  (no DHCP lease yet)  │            │
            │                       │            │
            │  enx1c860b363f63 (physical LAN NIC)│
            └───────────┬────────────────────────┘
                        │
               [TL-SG2008 switch]
               switch mgmt: 10.0.0.2 (target)
                        │
          ┌─────────────┼─────────────┐
          │             │             │
       [CP2]         [CP3]     [Workers 1-3]
     10.0.0.11     10.0.0.12   10.0.0.20-22
   (not deployed) (not deployed) (not deployed)

Legend:
  (×) = unreachable / unconfirmed
  LAN subnet: 10.0.0.0/24
```

### Infrastructure Summary

| Component | Type | IP | Status |
|---|---|---|---|
| Proxmox host | Physical server | 10.0.0.3 | Running |
| OPNsense (home-router) | VM 101 | WAN: 192.168.1.101 / LAN: 10.0.0.1 | Running — LAN unreachable from host |
| TL-SG2008 switch | Physical switch | 10.0.0.2 (target) | Connected — VLAN config pending |
| Talos CP1 | VM 100 | 10.0.0.10 (target) | Running — no DHCP lease confirmed |
| Talos CP2/CP3 | Physical nodes | 10.0.0.11-12 (target) | Not deployed |
| Workers 1-3 | Physical nodes | 10.0.0.20-22 (target) | Not deployed |

> For full details, see [homelab-current-state.md](homelab-current-state.md) and [talos-current-vs-planned.md](talos-current-vs-planned.md).

---

## 2. Phase A — Fix Networking

**Goal:** OPNsense serves DHCP on the LAN, CP1 gets IP 10.0.0.10, and the Proxmox host can reach the LAN subnet.

> **Why this phase matters:** Every subsequent phase is blocked until CP1 has a working IP address. This is the single highest-priority fix.

---

### A1: Verify OPNsense LAN Interface

**Where:** OPNsense Web UI

1. Open a browser and navigate to `https://192.168.1.101`
   - This accesses OPNsense via the WAN interface, which is reachable from the Proxmox host's WAN network.
   - Accept the self-signed certificate warning.
   - Login with your OPNsense admin credentials.

2. Navigate to **Interfaces → LAN**

3. Verify these settings:

| Setting | Expected Value |
|---|---|
| Enable | Checked (✓) |
| IPv4 Configuration Type | Static IPv4 |
| IPv4 Address | `10.0.0.1` |
| Subnet mask | `/24` (255.255.255.0) |
| Interface | `vtnet1` (the second NIC, connected to vmbr1) |

4. If any values are wrong, correct them, click **Save**, then **Apply Changes**.

> **Warning:** If the LAN interface is disabled or misconfigured, fix it now before proceeding. Changing the LAN interface assignment while connected via WAN is safe — your WAN-side access will not be interrupted.

---

### A2: Verify/Enable DHCP and Add CP1 Static Mapping

**Where:** OPNsense Web UI

#### Verify DHCP is enabled

1. Navigate to **Services → DHCPv4 → LAN**
2. Ensure the checkbox at the top is **checked** (Enable DHCP server on the LAN interface)
3. If DHCP range is not set, configure:

| Setting | Value |
|---|---|
| Range from | `10.0.0.100` |
| Range to | `10.0.0.200` |
| DNS servers | `10.0.0.1` |
| Gateway | `10.0.0.1` |

4. Click **Save**

#### Add CP1 static DHCP mapping

5. On the same page, scroll down to **DHCP Static Mappings for this Interface**
6. Click **+ Add**
7. Fill in:

| Setting | Value |
|---|---|
| MAC Address | `BC:24:11:FC:76:0A` |
| IP Address | `10.0.0.10` |
| Hostname | `talos-cp-1` |
| Description | `Talos Control Plane 1 (VM)` |

8. Click **Save**
9. Click **Apply Changes** at the top of the page

#### Check for existing leases

10. Navigate to **Services → DHCPv4 → Leases**
11. Look for any entry with MAC `BC:24:11:FC:76:0A`
    - If there is an existing lease with a different IP, delete it so the static mapping takes effect.

---

### A3: Add Proxmox Host Route to LAN

**Where:** Proxmox host shell (SSH or console)

The Proxmox host sits on vmbr1 but has no route to the 10.0.0.0/24 subnet. Without this route, you cannot reach any LAN device from the host.

#### Temporary route (immediate, lost on reboot)

```bash
ssh root@10.0.0.3
ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1
```

#### Verify the route was added

```bash
ip route show | grep 10.0.0
# Expected: 10.0.0.0/24 via 10.0.0.1 dev vmbr1
```

#### Test connectivity to OPNsense LAN

```bash
ping -c 3 10.0.0.1
# Should get replies
```

#### Make the route permanent (optional, recommended)

To survive reboots, add the route to `/etc/network/interfaces` on the Proxmox host. Add this line to the `vmbr1` stanza:

```
# In /etc/network/interfaces, inside the vmbr1 block:
    post-up ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1
    pre-down ip route del 10.0.0.0/24 via 10.0.0.1 dev vmbr1
```

The full vmbr1 stanza should look like:

```
iface vmbr1 inet manual
    bridge-ports enx1c860b363f63 fwpr100p0
    bridge-stp off
    bridge-fd 0
    post-up ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1
    pre-down ip route del 10.0.0.0/24 via 10.0.0.1 dev vmbr1
```

> **Note:** Do NOT add `bridge-vlan-aware yes` yet — that's Phase D. Adding it now without completing the VLAN setup on OPNsense and the switch could break LAN connectivity.

---

### A4: Reboot CP1 and Confirm DHCP Lease

**Where:** Proxmox host shell or Proxmox UI

#### Reboot CP1

```bash
ssh root@10.0.0.3 "qm reboot 100"
```

Or from the Proxmox UI at `https://10.0.0.3:8006`:
- Select VM 100 (talos-cp-1) → **Reboot**

#### Wait for boot (30-60 seconds)

#### Verify DHCP lease

**Method 1 — OPNsense leases:**

1. In OPNsense UI → **Services → DHCPv4 → Leases**
2. Look for MAC `BC:24:11:FC:76:0A` with IP `10.0.0.10`

**Method 2 — Ping from Proxmox host:**

```bash
ssh root@10.0.0.3 "ping -c 3 10.0.0.10"
# Should get replies
```

**Method 3 — Check Proxmox ARP table:**

```bash
ssh root@10.0.0.3 "arp -a | grep 10.0.0.10"
# Should show an entry for 10.0.0.10
```

#### If CP1 still has no IP

If none of the methods above show a lease or ARP entry:

1. Check Proxmox console for CP1 (VM 100) — look at the Talos maintenance screen. It may show `waiting for network` or similar.
2. Verify the MAC address matches — in Proxmox UI, select VM 100 → Hardware → Network Device → confirm MAC is `BC:24:11:FC:76:0A`.
3. Check OPNsense DHCP logs: **System → Log Files → DHCPd** — look for DHCPDISCOVER messages from that MAC.
4. If DHCP is sending offers but CP1 isn't accepting: the VM may be booting from the ISO into a state that doesn't send DHCP requests. See Phase B about detaching the ISO.

---

### A5: Regenerate OPNsense API Credentials

**Where:** OPNsense Web UI + local `terraform.tfvars`

The OPNsense API currently returns 401 Unauthorized, meaning the API key/secret in Terraform is stale.

#### Generate new API credentials

1. In OPNsense UI → **System → Access → Users**
2. Click the edit icon (pencil) next to the API user (or the admin user if that's what you're using)
3. Scroll down to **API keys**
4. Click **+ Add** (the plus icon) to generate a new key/secret pair
5. **Download the key file immediately** — the secret is only shown once
6. The downloaded file contains both the key and the secret

#### Update Terraform variables

Edit `terraform/terraform.tfvars` on your workstation:

```hcl
opnsense_api_key    = "your-new-api-key"
opnsense_api_secret = "your-new-api-secret"
```

#### Verify API access

```bash
curl -k -u "your-new-api-key:your-new-api-secret" \
  https://192.168.1.101/api/core/firmware/status
```

Expected: a JSON response (not 401 Unauthorized).

> **Note:** The OPNsense API URI in `terraform.tfvars` should use the WAN IP (`https://192.168.1.101`) until the Proxmox host route is confirmed working. Once Phase A is complete you can switch to `https://10.0.0.1` if you prefer.

---

### Phase A Checkpoint

Before moving to Phase B, verify all of the following:

| Check | Command / Method | Expected Result |
|---|---|---|
| OPNsense LAN is up | OPNsense UI → Interfaces → LAN | Enabled, 10.0.0.1/24, vtnet1 |
| DHCP is serving leases | OPNsense UI → Services → DHCPv4 → LAN | Enabled, range 10.0.0.100-200 |
| CP1 static mapping exists | OPNsense UI → DHCPv4 → LAN → Static Mappings | MAC `BC:24:11:FC:76:0A` → 10.0.0.10 |
| Proxmox host route | `ssh root@10.0.0.3 "ip route show \| grep 10.0.0"` | `10.0.0.0/24 via 10.0.0.1 dev vmbr1` |
| Proxmox can reach OPNsense LAN | `ssh root@10.0.0.3 "ping -c 1 10.0.0.1"` | Reply received |
| CP1 has IP 10.0.0.10 | `ssh root@10.0.0.3 "ping -c 1 10.0.0.10"` | Reply received |
| OPNsense API works | `curl -k -u key:secret https://192.168.1.101/api/core/firmware/status` | JSON response (200 OK) |

> **Stop here if any check fails.** Debug using the troubleshooting steps in each sub-section above. Do not proceed to Phase B with broken networking.

---

## 3. Phase B — Get CP1 Operational

**Goal:** CP1 runs as a Terraform-managed Talos VM, booting from disk with the Talos machine configuration applied.

---

### Decision Point: Import VM 100 vs. Recreate as VM 200

The existing VM 100 was manually created and doesn't match Terraform's expected configuration:

| Property | VM 100 (actual) | Terraform config (planned VM 200) |
|---|---|---|
| VMID | 100 | 200 |
| RAM | 6.9 GB (7065 MB) | 4 GB (4096 MB) |
| Disk | 108 GB | 32 GB |
| CPU | 2 cores | 2 cores |
| Created by | Manual | Terraform |

| | Option A: Import VM 100 | Option B: Destroy + Recreate as VM 200 |
|---|---|---|
| **Pros** | No downtime, preserves existing disk | Clean state, matches Terraform exactly |
| **Cons** | Must update Terraform vars to match VM 100 specs (VMID, RAM, disk), or accept drift | Destroys existing VM, full reprovisioning |
| **When to choose** | If you want to keep the 108 GB disk and 6.9 GB RAM | If you want a clean, minimal setup matching Terraform defaults |
| **Effort** | Low — one import command + var updates | Medium — destroy VM, run apply, wait for ISO boot + config |

> **Recommendation:** Option B (destroy and recreate) gives you a clean slate that matches all your Terraform configurations. Since the cluster has never been bootstrapped and CP1 has no data, there's nothing to lose.

---

### B1: Execute Chosen Option

#### Option A — Import existing VM 100

```bash
cd terraform

# Update variables to match actual VM 100
# In terraform.tfvars, set:
#   talos_cp1_vm_id  = 100
#   talos_cp_memory  = 7065
#   talos_cp_disk_size = 108

# Import the VM into Terraform state
terraform import proxmox_virtual_environment_vm.talos_cp1 home/100

# Verify state matches
terraform plan
# Review the plan — ideally no changes. Fix any remaining drift.
```

#### Option B — Destroy VM 100 and recreate

```bash
# From Proxmox host: stop and destroy VM 100
ssh root@10.0.0.3 "qm stop 100 && qm destroy 100"

# From your workstation:
cd terraform

# Ensure terraform.tfvars has the default values:
#   talos_cp1_vm_id  = 200
#   talos_cp_memory  = 4096
#   talos_cp_disk_size = 32

# Clean any stale state
terraform state rm proxmox_virtual_environment_vm.talos_cp1 2>/dev/null || true
```

---

### B2: Run Terraform Apply

```bash
cd terraform

# Initialize (if not already done)
terraform init

# Plan to see what will be created
terraform plan

# Apply — this creates the VM, downloads the ISO, generates Talos secrets,
# and applies the machine configuration
terraform apply
```

**What this does (in order):**

1. Downloads the Talos ISO to Proxmox storage (`proxmox_virtual_environment_download_file.talos_iso`)
2. Generates Talos cluster secrets (`talos_machine_secrets.this`)
3. Creates the VM (`proxmox_virtual_environment_vm.talos_cp1`)
4. VM boots from ISO into Talos maintenance mode
5. Applies Talos machine config to the node (`talos_machine_configuration_apply.cp1`)

> **Warning:** Step 5 (`talos_machine_configuration_apply`) will fail if CP1 cannot be reached at 10.0.0.10. If this happens, ensure Phase A is complete and the DHCP lease is active. You may need to wait for the VM to boot and acquire its IP before re-running `terraform apply`.

**Watch the Proxmox console** during apply: open `https://10.0.0.3:8006`, select the CP1 VM, and click **Console** to see the Talos boot output.

---

### B3: Detach ISO

After Terraform applies the machine configuration, Talos installs itself to disk. The ISO is no longer needed and should be detached to prevent accidental re-imaging on future reboots.

```bash
# Determine the VMID (100 if imported, 200 if recreated)
VMID=200  # adjust if you chose Option A

ssh root@10.0.0.3 "qm set ${VMID} --ide2 none,media=cdrom"
```

> **Note:** The Terraform `lifecycle.ignore_changes` block on the VM resource includes `cdrom` and `boot_order`, so this manual change won't cause drift on the next `terraform apply`.

---

### B4: Verify CP1 Boots from Disk

After detaching the ISO, reboot CP1 to confirm it boots from the installed disk:

```bash
ssh root@10.0.0.3 "qm reboot ${VMID}"
```

Wait 60-90 seconds, then verify:

```bash
# From your workstation
ping -c 3 10.0.0.10
# Should get replies

# Check Talos is responding
talosctl --nodes 10.0.0.10 version --insecure
# Should show Talos version info
```

If the node boots back into maintenance mode (ISO installer), the install-to-disk step may not have completed. Check the Proxmox console and re-apply:

```bash
terraform apply -target=talos_machine_configuration_apply.cp1
```

---

### Phase B Checkpoint

| Check | Command / Method | Expected Result |
|---|---|---|
| VM exists in Terraform state | `terraform state list \| grep talos_cp1` | `proxmox_virtual_environment_vm.talos_cp1` listed |
| VM is running | Proxmox UI → VM list | CP1 (VM 100 or 200) status: running |
| ISO detached | `ssh root@10.0.0.3 "qm config ${VMID} \| grep ide2"` | No IDE2 entry, or `none,media=cdrom` |
| CP1 has IP 10.0.0.10 | `ping -c 1 10.0.0.10` | Reply received |
| Talos API responds | `talosctl --nodes 10.0.0.10 version --insecure` | Talos version output |
| Terraform plan is clean | `terraform plan` | No changes (or only expected changes) |

---

## 4. Phase C — Bootstrap Cluster

**Goal:** Bootstrap etcd, start the Kubernetes control plane, generate kubeconfig, and verify the VIP.

---

### C1: Export talosconfig

The Talos client configuration is needed for `talosctl` to authenticate with the cluster.

```bash
# Create talos config directory
mkdir -p ~/.talos

# Export from Terraform output
cd terraform
terraform output -raw talosconfig > ~/.talos/config

# Set environment variable (add to ~/.zshrc for persistence)
export TALOSCONFIG=~/.talos/config

# Verify the config
talosctl config info
# Should show cluster name: homelab-cluster
# Endpoints: 10.0.0.10
```

---

### C2: Bootstrap etcd

> **WARNING: Run this command EXACTLY ONCE on the FIRST control plane node. Running bootstrap again can corrupt etcd and require a full cluster reset.**

```bash
talosctl bootstrap --nodes 10.0.0.10 --endpoints 10.0.0.10
```

This initializes:
- etcd single-member cluster
- Kubernetes control plane components (API server, controller-manager, scheduler)
- Core system pods (kube-proxy, CoreDNS)

**Wait 2-5 minutes** for bootstrap to complete.

#### Monitor progress

```bash
# Stream kernel/system logs to watch bootstrap
talosctl dmesg -f --nodes 10.0.0.10

# Or use the interactive dashboard
talosctl dashboard --nodes 10.0.0.10
```

#### If bootstrap fails

```bash
# Check etcd logs
talosctl logs etcd --nodes 10.0.0.10

# Check controller-runtime logs
talosctl logs controller-runtime --nodes 10.0.0.10

# If etcd is already bootstrapped (ran bootstrap twice)
talosctl etcd members --nodes 10.0.0.10
# If this shows members, bootstrap already completed — skip to C3
```

---

### C3: Generate kubeconfig

```bash
# Export kubeconfig
talosctl kubeconfig --nodes 10.0.0.10 -f ~/.kube/config

# Verify cluster access
kubectl cluster-info
# Should show: Kubernetes control plane is running at https://10.0.0.5:6443

kubectl get nodes
# Expected:
# NAME         STATUS     ROLES           AGE   VERSION
# talos-cp-1   Ready      control-plane   2m    v1.31.0
```

> **Note:** The node may show `NotReady` initially if no CNI is installed. This is expected — Cilium is installed in Phase F. The node status should become `Ready` for control plane components even without a CNI on a single-node cluster.

---

### C4: Verify VIP (10.0.0.5)

The Virtual IP should be active on CP1 since it's the only control plane node.

```bash
# Ping the VIP
ping -c 3 10.0.0.5
# Should get replies from 10.0.0.10

# Access the API via VIP
kubectl --server=https://10.0.0.5:6443 get nodes
# Should work — confirms VIP is routing to the API server
```

If the VIP doesn't respond:

```bash
# Check if VIP is assigned on the node
talosctl get addresses --nodes 10.0.0.10
# Should show 10.0.0.5 on eth0

# Check VIP-related logs
talosctl logs controller-runtime --nodes 10.0.0.10 | grep -i vip
```

---

### C5: Health Check

```bash
# Full cluster health check
talosctl health --nodes 10.0.0.10
# Expected output:
# discovered nodes: ["10.0.0.10"]
# service "etcd" is healthy
# service "kubelet" is healthy
# ...
# all checks passed!

# Check all Talos services
talosctl services --nodes 10.0.0.10
# All services should show "Running"

# Interactive dashboard (press Ctrl-C to exit)
talosctl dashboard --nodes 10.0.0.10
```

#### Verify core system pods

```bash
kubectl get pods -A
# Expected namespaces with running pods:
# kube-system: coredns, kube-apiserver, kube-controller-manager,
#              kube-proxy, kube-scheduler, etcd
```

---

### Phase C Checkpoint

| Check | Command | Expected Result |
|---|---|---|
| etcd is healthy | `talosctl etcd members --nodes 10.0.0.10` | 1 member listed (CP1) |
| Kubernetes API responds | `kubectl get nodes` | 1 node in Ready state |
| VIP is active | `ping -c 1 10.0.0.5` | Reply from 10.0.0.10 |
| API via VIP works | `kubectl --server=https://10.0.0.5:6443 get nodes` | Node list returned |
| talosctl health passes | `talosctl health --nodes 10.0.0.10` | "all checks passed!" |
| System pods running | `kubectl get pods -n kube-system` | All pods Running or Completed |
| kubeconfig saved | `cat ~/.kube/config \| grep server` | `https://10.0.0.5:6443` |

---

## 5. Phase D — Network Hardening / VLAN

**Goal:** Isolate the homelab network on VLAN 10 with proper 802.1Q tagging across Proxmox, OPNsense, and the SG2008 switch.

> **When to do Phase D:** This phase is optional for getting the cluster running but recommended before connecting physical nodes. You can proceed to Phase E without VLANs if you want to get the full cluster running first, then come back to harden networking.

---

### Decision Point: VLAN Approach

| | Option A: Single VLAN, No Trunk (Recommended) | Option B: VLAN Trunk (Multi-VLAN Ready) |
|---|---|---|
| **How it works** | LAN stays untagged on `vtnet1`. VLAN 10 is a switch-internal concept only. No Proxmox changes needed. | `vmbr1` becomes VLAN-aware. OPNsense uses a `vtnet1_vlan10` subinterface. Frames are tagged on the bridge. |
| **Pros** | Simple, no risk of lockout, works today | Supports multiple VLANs in the future (IoT, guest, etc.) |
| **Cons** | Cannot add more VLANs later without reconfiguration | More complex, risk of OPNsense lockout if steps are done out of order |
| **When to choose** | Single homelab subnet is sufficient for now | You plan to add IoT/guest VLANs soon |

> **Recommendation:** Start with **Option A** (single VLAN, no trunk). This gets VLAN 10 working on the switch without touching the Proxmox bridge or OPNsense. You can upgrade to Option B later when you need multiple VLANs.

---

### D1: Configure Proxmox Bridge (Option B only)

> **Skip this step if using Option A.**

If you chose Option B (trunk mode), enable VLAN-aware on vmbr1:

```bash
# On Proxmox host
ssh root@10.0.0.3

# Edit /etc/network/interfaces — add bridge-vlan-aware yes to vmbr1
# Then reload:
ifreload -a
```

See [opnsense-vlan-setup.md — Section 7: Option B](opnsense-vlan-setup.md#7-option-b-vlan-trunk-multi-vlan-ready) for the full procedure.

> **Warning:** If you enable VLAN-aware on vmbr1 WITHOUT first setting up the VLAN subinterface on OPNsense, you may lose LAN connectivity. Follow the exact order in the VLAN setup guide.

---

### D2: Configure OPNsense VLAN 10

Follow the detailed procedure in [opnsense-vlan-setup.md](opnsense-vlan-setup.md):
- **Option A:** Section 6 — steps A1 through A3
- **Option B:** Section 7 — steps B1 through B4

Key configuration:
- VLAN tag: 10
- Description: `homelab-lan`
- Parent interface: `vtnet1`
- IP: `10.0.0.1/24` (on the VLAN interface for Option B, or leave on LAN for Option A)

---

### D3: Configure SG2008 Switch

Follow the detailed procedure in [switch-setup-guide.md](switch-setup-guide.md) Section 7, and [opnsense-vlan-setup.md](opnsense-vlan-setup.md) steps A4-A6 or B5-B6.

Key configuration:
- Create VLAN 10 (`homelab-lan`)
- Port membership: Ports 1-7 untagged, Port 8 untagged (Option A) or tagged (Option B)
- Set PVID = 10 on all ports
- Set management IP to 10.0.0.2 on VLAN 10

---

### D4: End-to-End VLAN Verification

After configuring all three components:

```bash
# From Proxmox host
ssh root@10.0.0.3

# Verify route to LAN
ping -c 1 10.0.0.1    # OPNsense LAN gateway
ping -c 1 10.0.0.10   # Talos CP1
ping -c 1 10.0.0.2    # Switch management (if configured)

# Verify CP1 can reach the gateway
talosctl get routes --nodes 10.0.0.10
# Should show default route via 10.0.0.1
```

---

### Phase D Checkpoint

| Check | Command / Method | Expected Result |
|---|---|---|
| VLAN 10 exists on switch | Switch UI → L2 Features → 802.1Q VLAN | VLAN 10 `homelab-lan` listed |
| Switch management IP | `ping -c 1 10.0.0.2` (from Proxmox host) | Reply received |
| CP1 connectivity preserved | `ping -c 1 10.0.0.10` | Reply received |
| CP1 → gateway works | `talosctl get routes --nodes 10.0.0.10` | Default route via 10.0.0.1 |
| VIP still responds | `ping -c 1 10.0.0.5` | Reply received |

---

## 6. Phase E — Scale to Full Cluster

**Goal:** Expand from 1 control plane VM to a 3-node HA control plane + 3 worker nodes.

---

### E1: Prepare Talos USB Boot Media

Download and write the Talos image to a USB drive for physical node installation:

```bash
# Set version to match your cluster
export TALOS_VERSION="v1.9.0"

# Download raw image
curl -LO "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.raw.xz"

# Decompress
xz -d metal-amd64.raw.xz

# Write to USB drive (replace /dev/diskN with your USB device)
# On macOS, find your USB with: diskutil list
sudo dd if=metal-amd64.raw of=/dev/rdiskN bs=4m status=progress
sync
```

> **Warning:** Double-check the target device (`/dev/rdiskN`) — `dd` will overwrite without confirmation. Use `diskutil list` to identify the correct USB drive.

---

### E2: Deploy CP2 (Physical Node)

#### Prepare OPNsense DHCP mapping

1. In OPNsense UI → **Services → DHCPv4 → LAN → DHCP Static Mappings → + Add**
2. Fill in:
   - MAC Address: (get from the physical node's NIC — check the label or boot the node and find the MAC in DHCP leases)
   - IP Address: `10.0.0.11`
   - Hostname: `talos-cp-2`
3. **Save** → **Apply Changes**

#### Boot and configure

1. Insert the Talos USB drive into the CP2 physical machine
2. Boot from USB (press F12/F2/Del for boot menu, select USB)
3. Wait for Talos maintenance mode — you'll see `waiting for configuration...` on the console
4. Note the DHCP-assigned IP (or check OPNsense leases for the node's MAC)

```bash
export TALOS_CP2="10.0.0.11"

# Apply control plane configuration
talosctl apply-config --insecure \
    --nodes $TALOS_CP2 \
    --file controlplane.yaml
```

> **Note:** The `controlplane.yaml` file must be generated from the same secrets as CP1. If you used Terraform to generate CP1's config, extract the secrets:
>
> ```bash
> cd terraform
> # Generate configs using the same secrets
> talosctl gen config homelab-cluster https://10.0.0.5:6443 \
>     --with-secrets <(terraform output -raw machine_secrets) \
>     --output-dir ./configs \
>     --config-patch-control-plane @control-plane-patch.yaml
> ```
>
> If `machine_secrets` is not an output, you can generate a config from the Terraform state. See [talos-setup-guide.md](talos-setup-guide.md) Part 2 for the config generation process.

Wait for the node to install and reboot (2-5 minutes).

---

### E3: Deploy CP3 (Physical Node)

Repeat the same process as E2:

1. Add DHCP static mapping for CP3's MAC → `10.0.0.12` (hostname: `talos-cp-3`)
2. Boot from Talos USB
3. Apply config:

```bash
export TALOS_CP3="10.0.0.12"

talosctl apply-config --insecure \
    --nodes $TALOS_CP3 \
    --file controlplane.yaml
```

---

### Decision Point: Automate CP2/CP3 in Terraform?

| | Add to Terraform | Keep manual (talosctl) |
|---|---|---|
| **Pros** | Consistent IaC, version-controlled config | Faster iteration, simpler for physical nodes |
| **Cons** | Physical nodes are harder to manage via Terraform (no VM lifecycle) | Config drift risk, manual process |
| **When to choose** | If you want full IaC consistency | If physical nodes are set-and-forget |

> **Recommendation:** Keep CP2/CP3 manual via `talosctl` for now. Physical nodes don't benefit much from Terraform's VM lifecycle management. You can always add `talos_machine_configuration_apply` resources later for config management.

---

### E4: Verify 3-Node HA

After all three control plane nodes are up:

```bash
# Update talosctl endpoints to include all control planes
talosctl config endpoint 10.0.0.10 10.0.0.11 10.0.0.12

# Verify etcd cluster has 3 members
talosctl etcd members
# Expected: 3 members listed

# Check all nodes in Kubernetes
kubectl get nodes -o wide
# Expected:
# NAME         STATUS   ROLES           AGE   VERSION   INTERNAL-IP
# talos-cp-1   Ready    control-plane   1h    v1.31.0   10.0.0.10
# talos-cp-2   Ready    control-plane   5m    v1.31.0   10.0.0.11
# talos-cp-3   Ready    control-plane   3m    v1.31.0   10.0.0.12

# Full health check
talosctl health
# Should show: all checks passed!
```

#### Test VIP failover

```bash
# Note which node currently holds the VIP
talosctl get addresses --nodes 10.0.0.10 | grep 10.0.0.5

# Reboot the node holding the VIP
talosctl reboot --nodes 10.0.0.10

# While CP1 is rebooting, test VIP
ping 10.0.0.5
# Should still respond (VIP moved to CP2 or CP3)

kubectl get nodes
# API should still work through VIP
```

---

### E5: Deploy Workers 1-3

For each worker node (repeat for workers 1, 2, and 3):

#### Add DHCP mappings

In OPNsense UI, add static mappings:

| Hostname | MAC | IP |
|---|---|---|
| talos-worker-1 | (from hardware) | 10.0.0.20 |
| talos-worker-2 | (from hardware) | 10.0.0.21 |
| talos-worker-3 | (from hardware) | 10.0.0.22 |

#### Boot and configure

```bash
export TALOS_W1="10.0.0.20"
export TALOS_W2="10.0.0.21"
export TALOS_W3="10.0.0.22"

# Apply worker config to each node
talosctl apply-config --insecure --nodes $TALOS_W1 --file worker.yaml
talosctl apply-config --insecure --nodes $TALOS_W2 --file worker.yaml
talosctl apply-config --insecure --nodes $TALOS_W3 --file worker.yaml
```

> **Note:** The `worker.yaml` is generated alongside `controlplane.yaml` in step E2. See [talos-setup-guide.md](talos-setup-guide.md) Part 2 for the worker patch and config generation.

#### Label worker nodes

```bash
kubectl label node talos-worker-1 node-role.kubernetes.io/worker=worker
kubectl label node talos-worker-2 node-role.kubernetes.io/worker=worker
kubectl label node talos-worker-3 node-role.kubernetes.io/worker=worker
```

---

### Decision Point: Keep `allowSchedulingOnControlPlanes`?

The current Terraform config sets `allowSchedulingOnControlPlanes: true`.

| | Keep `true` | Set to `false` |
|---|---|---|
| **Pros** | More schedulable resources, useful with 3 small workers | Control planes are dedicated, less risk of resource contention |
| **Cons** | Workloads on CPs can starve etcd/API server | 3 workers may not have enough resources for all workloads |
| **When to choose** | If total cluster resources are limited | If workers have plenty of capacity |

> **Recommendation:** Keep `true` for now. With a small homelab, you'll want every node available for workloads. Revisit after you know your actual resource usage.

---

### Phase E Checkpoint

| Check | Command | Expected Result |
|---|---|---|
| 3 CP nodes in etcd | `talosctl etcd members` | 3 members |
| 6 nodes in Kubernetes | `kubectl get nodes -o wide` | 3 control-plane + 3 worker nodes, all Ready |
| VIP failover works | Reboot VIP holder, `ping 10.0.0.5` | VIP moves, ping continues |
| Health check passes | `talosctl health` | "all checks passed!" |
| Workers labeled | `kubectl get nodes --show-labels \| grep worker` | worker role label on 3 nodes |

---

## 7. Phase F — Platform Services

**Goal:** Install the CNI, load balancer, GitOps pipeline, and observability stack.

---

### F1: Install Cilium CNI

Cilium provides pod networking and replaces kube-proxy:

```bash
# Install Helm (if not already installed)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add Cilium repo
helm repo add cilium https://helm.cilium.io/
helm repo update

# Install Cilium
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"

# Wait for Cilium to be ready
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=cilium --timeout=120s

# Verify
kubectl get pods -n kube-system -l k8s-app=cilium
# All Cilium pods should be Running (one per node)
```

After Cilium is installed, nodes that were `NotReady` due to missing CNI should become `Ready`:

```bash
kubectl get nodes
# All nodes should now show Ready
```

---

### F2: Install MetalLB

MetalLB provides LoadBalancer service support for bare-metal clusters:

```bash
# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Wait for MetalLB pods
kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=90s

# Configure IP address pool and L2 advertisement
cat <<'EOF' | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.0.0.50-10.0.0.99
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF

# Verify
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

#### Test MetalLB (optional)

```bash
# Deploy a simple test service
kubectl create deployment nginx-test --image=nginx --port=80
kubectl expose deployment nginx-test --type=LoadBalancer --port=80

# Check the assigned external IP
kubectl get svc nginx-test
# EXTERNAL-IP should be in 10.0.0.50-99 range

# Test access
curl http://<EXTERNAL-IP>
# Should return nginx welcome page

# Clean up
kubectl delete deployment nginx-test
kubectl delete svc nginx-test
```

---

### F3: Deploy ArgoCD

ArgoCD provides GitOps-based continuous delivery.

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods
kubectl -n argocd wait --for=condition=ready pod --all --timeout=120s

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d && echo

# Access ArgoCD UI (via port-forward for initial setup)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Then open https://localhost:8080
# Login: admin / <password from above>
```

> For the full ArgoCD configuration (repositories, applications, RBAC), see [argocd-setup-guide.md](argocd-setup-guide.md).

---

### F4: Set Up Observability

The observability stack uses a two-tier approach: Grafana Cloud for infrastructure monitoring and in-cluster Grafana/SigNoz for application observability.

```bash
# Install Grafana Alloy (for sending metrics/logs to Grafana Cloud)
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Prometheus + Grafana for in-cluster monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace
```

> For the complete observability setup (Grafana Cloud integration, SigNoz, dashboards), see [observability-guide.md](observability-guide.md).

---

### Phase F Checkpoint

| Check | Command | Expected Result |
|---|---|---|
| Cilium running | `kubectl get pods -n kube-system -l k8s-app=cilium` | 1 pod per node, all Running |
| All nodes Ready | `kubectl get nodes` | All 6 nodes Ready |
| MetalLB ready | `kubectl get pods -n metallb-system` | Controller + speaker pods Running |
| IP pool configured | `kubectl get ipaddresspool -n metallb-system` | `default-pool` with 10.0.0.50-99 |
| ArgoCD running | `kubectl get pods -n argocd` | All pods Running |
| ArgoCD UI accessible | `kubectl port-forward svc/argocd-server -n argocd 8080:443` | UI loads at localhost:8080 |

---

## 8. Decisions Reference

All decision points consolidated:

| # | Decision | Options | Recommendation | Phase |
|---|---|---|---|---|
| 1 | Keep VM 100 or recreate as VM 200? | Import existing / Destroy and recreate | **Recreate** — clean slate, no data to lose | B |
| 2 | VLAN: single-VLAN (Option A) or trunk (Option B)? | Option A (no trunk) / Option B (trunk) | **Option A** — simpler, upgrade later if needed | D |
| 3 | Automate CP2/CP3 in Terraform? | Add to Terraform / Keep manual | **Keep manual** — physical nodes don't benefit from VM lifecycle | E |
| 4 | Keep `allowSchedulingOnControlPlanes: true`? | Yes / No | **Yes** — maximize available resources in a small cluster | E |
| 5 | Talos version: stay on v1.9.0 or upgrade? | Stay / Upgrade | **Stay on v1.9.0** — get the cluster working first, upgrade later | All |

---

## 9. Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---|---|---|
| CP1 has no IP (no DHCP lease) | OPNsense DHCP not running or no static mapping | Phase A: Steps A1-A2 — enable DHCP, add static mapping |
| `ping 10.0.0.1` fails from Proxmox | No host route to LAN subnet | Phase A: Step A3 — `ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1` |
| OPNsense API returns 401 | Stale API key/secret | Phase A: Step A5 — regenerate API credentials |
| `terraform apply` hangs on `talos_machine_configuration_apply` | CP1 unreachable at 10.0.0.10 | Complete Phase A first, verify `ping 10.0.0.10` works |
| VM boots into ISO installer instead of Talos | ISO still attached, boot order wrong | Phase B: Step B3 — detach ISO with `qm set <VMID> --ide2 none,media=cdrom` |
| `talosctl bootstrap` errors "already bootstrapped" | Bootstrap was already run | Skip to C3 — check `talosctl etcd members` |
| VIP (10.0.0.5) not responding | VIP not configured or node not fully bootstrapped | Check `talosctl get addresses --nodes 10.0.0.10` for VIP assignment |
| Nodes show `NotReady` | No CNI installed | Expected until Phase F — install Cilium |
| Lost OPNsense LAN access after VLAN changes | VLAN misconfiguration — bridge/switch/OPNsense out of sync | See [opnsense-vlan-setup.md](opnsense-vlan-setup.md) Section 5 for recovery via Proxmox console |
| `kubectl` commands fail with connection refused | kubeconfig pointing to wrong endpoint, or API server not running | Verify `kubectl config view` shows `server: https://10.0.0.5:6443`, check `talosctl services --nodes 10.0.0.10` |

---

## 10. Network Quick Reference

| Device | Role | IP | MAC |
|---|---|---|---|
| Main router | Internet gateway | 192.168.1.1 | — |
| Proxmox host | Hypervisor | 10.0.0.3 (WAN: 192.168.1.110) | — |
| OPNsense (VM 101) | Firewall / Router / DHCP | LAN: 10.0.0.1, WAN: 192.168.1.101 | WAN: `BC:24:11:2B:01:8B` |
| TL-SG2008 switch | L2 switch | 10.0.0.2 (target) | (on label) |
| talos-cp-1 (VM) | Control Plane 1 | 10.0.0.10 | `BC:24:11:FC:76:0A` |
| talos-cp-2 (physical) | Control Plane 2 | 10.0.0.11 | (from hardware) |
| talos-cp-3 (physical) | Control Plane 3 | 10.0.0.12 | (from hardware) |
| talos-worker-1 (physical) | Worker 1 | 10.0.0.20 | (from hardware) |
| talos-worker-2 (physical) | Worker 2 | 10.0.0.21 | (from hardware) |
| talos-worker-3 (physical) | Worker 3 | 10.0.0.22 | (from hardware) |
| Kubernetes API VIP | HA API endpoint | 10.0.0.5 | — |
| MetalLB pool | LoadBalancer IPs | 10.0.0.50–10.0.0.99 | — |
| DHCP dynamic pool | Auto-assigned IPs | 10.0.0.100–10.0.0.200 | — |

---

## 11. References

### Official Documentation

| Resource | URL |
|---|---|
| Talos Linux — Getting Started | https://www.talos.dev/v1.10/introduction/getting-started/ |
| Talos Linux on Proxmox | https://www.talos.dev/v1.10/talos-guides/install/virtualized-platforms/proxmox/ |
| Talos Linux — VIP Configuration | https://www.talos.dev/v1.10/talos-guides/network/vip/ |
| Terraform Talos Provider | https://registry.terraform.io/providers/siderolabs/talos/latest/docs |
| BPG Proxmox Provider | https://registry.terraform.io/providers/bpg/proxmox/latest/docs |
| Proxmox — Network Configuration | https://pve.proxmox.com/wiki/Network_Configuration |
| OPNsense — VLAN and LAGG Setup | https://docs.opnsense.org/manual/how-tos/vlan_and_lagg.html |
| TP-Link — 802.1Q VLAN on Omada Switches | https://www.tp-link.com/us/support/faq/2149/ |
| TP-Link — 802.1Q VLAN with 3rd-Party Router | https://www.tp-link.com/us/support/faq/4084/ |
| Cilium Documentation | https://docs.cilium.io/en/stable/ |
| MetalLB Documentation | https://metallb.universe.tf/ |
| ArgoCD Documentation | https://argo-cd.readthedocs.io/en/stable/ |

### Community Guides & Blog Posts

| Guide | URL |
|---|---|
| Eric Daly — Kubernetes Homelab Series (Talos on Proxmox) | https://blog.dalydays.com/post/kubernetes-homelab-series-part-1-talos-linux-proxmox/ |
| Talos on Proxmox with OpenTofu (IaC) — stonegarden.dev | https://blog.stonegarden.dev/articles/2024/08/talos-proxmox-tofu/ |
| HA Kubernetes on Proxmox with Terraform + Talos — itguyjournals.com | https://www.itguyjournals.com/deploying-ha-kubernetes-cluster-with-proxmox-terraform-and-talos-os/ |
| VLAN from Scratch — OPNsense + Proxmox + Switch — koromatech.com | https://koromatech.com/vlan-setup-from-scratch-opnsense-proxmox-switch-complete-guide/ |
| Talos Cluster on Proxmox with Terraform — olav.ninja | https://olav.ninja/talos-cluster-on-proxmox-with-terraform |
| IoT VLAN with OPNsense + TP-Link Omada — gaelanlloyd.com | https://www.gaelanlloyd.com/blog/iot-vlan-opnsense-omada-ipv6/ |
| OPNsense + Proxmox VLAN Trunk Setup — Proxmox Forum | https://forum.proxmox.com/threads/help-with-proxmox-trunk-port-setup-letting-opnsense-handle-vlans-dhcp-etc.167426/ |

### Repo Documentation Cross-References

| Document | Covers | Phases |
|---|---|---|
| [homelab-current-state.md](homelab-current-state.md) | Network diagram, connectivity matrix, VLAN directions, issue diagnosis | Context for all phases |
| [talos-current-vs-planned.md](talos-current-vs-planned.md) | Gap analysis, critical blockers, action plan | Source for this walkthrough |
| [talos-setup-guide.md](talos-setup-guide.md) | Manual Talos bootstrap (secrets, configs, apply-config, bootstrap) | C, E |
| [talos-cp1-terraform-guide.md](talos-cp1-terraform-guide.md) | Terraform-based CP1 deployment, Terraform file walkthrough | B |
| [talos-management-handbook.md](talos-management-handbook.md) | Day-2 operations (upgrades, reboots, etcd management) | Post-deployment |
| [opnsense-vlan-setup.md](opnsense-vlan-setup.md) | VLAN 10 setup on OPNsense (both options), lockout recovery | D |
| [switch-setup-guide.md](switch-setup-guide.md) | TL-SG2008 initial access from macOS, VLAN config | D |
| [argocd-setup-guide.md](argocd-setup-guide.md) | ArgoCD installation, app config, RBAC, repository setup | F |
| [observability-guide.md](observability-guide.md) | Grafana Cloud + in-cluster monitoring, two-tier strategy | F |
| [opnsense-configuration-guide.md](opnsense-configuration-guide.md) | OPNsense UI navigation, DHCP setup, firewall rules | A |
