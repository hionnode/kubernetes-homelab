# Homelab Current State

**Snapshot Date:** 2026-03-08
**Status:** Infrastructure partially deployed — OPNsense running, Talos CP1 booting but not yet joined

---

## Network Topology

```
                          INTERNET
                              |
                    [Main Router: 192.168.1.1]
                              |
                    WAN: 192.168.1.0/24
                              |
            ┌─────────────────┴──────────────────┐
            │         Proxmox Host               │
            │         192.168.1.110              │
            │                                    │
            │  vmbr0 (WAN bridge)                │
            │  ├── enp2s0 (physical WAN NIC)     │
            │  └── tap101i0 ─── VM 101 net0      │
            │                       │            │
            │                  [OPNsense]        │
            │              VM 101 / home-router  │
            │              WAN: 192.168.1.101    │
            │              LAN: 10.0.0.1 (×)    │
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
                        │  (VLAN 10 trunk)
               [TL-SG2008 switch]
               switch mgmt: 10.0.0.2
               VLAN 10: homelab-lan (10.0.0.0/24)
                        │
          ┌─────────────┼─────────────┐
          │             │             │
       [CP2]         [CP3]     [Workers 1-3]
     10.0.0.11     10.0.0.12   10.0.0.20-22
   (not deployed) (not deployed) (not deployed)

Legend:
  (×) = unreachable / unconfirmed
  LAN subnet: 10.0.0.0/24 (VLAN 10)
```

---

## Infrastructure Summary

| Component | Type | IP | Status |
|---|---|---|---|
| Proxmox host | Physical server | 192.168.1.110 | Running |
| OPNsense (home-router) | VM 101 | WAN: 192.168.1.101 / LAN: 10.0.0.1 | Running — LAN unreachable from host |
| TL-SG2008 switch | Physical switch | 10.0.0.2 (target) | Connected — VLAN config pending |
| Talos CP1 | VM 100 | 10.0.0.10 (target) | Running — no DHCP lease confirmed |
| Talos CP2 | Physical node | 10.0.0.11 (target) | Not deployed |
| Talos CP3 | Physical node | 10.0.0.12 (target) | Not deployed |
| Worker 1-3 | Physical nodes | 10.0.0.20-22 (target) | Not deployed |
| K8s API VIP | MetalLB / KubeVIP | 10.0.0.5 | Not configured |

---

## Proxmox Host

| Property | Value |
|---|---|
| IP | 192.168.1.110 |
| Reachable | Yes |
| WAN bridge | vmbr0 → enp2s0 + tap101i0 |
| LAN bridge | vmbr1 → enx1c860b363f63 + fwpr100p0 + tap101i1 |
| ARP: OPNsense WAN | 192.168.1.101 (confirmed) |
| ARP: Talos CP1 | Not present — no 10.0.0.10 entry |
| Route to 10.0.0.0/24 | None — host cannot reach LAN subnet directly |

---

## VM 100 — talos-cp-1

| Property | Value |
|---|---|
| VMID | 100 |
| Status | running |
| vCPU | 2 |
| RAM | 689 MB used / 6.9 GB max |
| Disk | 108 GB (scsi0) |
| Uptime | ~10 minutes at time of snapshot |
| Network | vmbr1 (LAN only) |
| MAC | BC:24:11:FC:76:0A |
| Firewall | Enabled |
| Boot order | scsi0 → ide2 (ISO) → net0 |
| ISO attached | talos-metal-amd64.iso (cdrom) |
| TX packets | 428 (~144 KB) |
| RX packets | 35 (~4 KB) |
| IP assigned | None confirmed (not in Proxmox ARP table) |
| talosconfig | Empty — no cluster context, cluster never bootstrapped |

**Status Assessment:** VM is running and broadcasting on vmbr1. Low RX packet count suggests DHCP requests are going unanswered or OPNsense DHCP is not responding to this MAC. VM is likely looping in DHCP discovery or has booted into Talos maintenance mode without an IP. ISO is still attached — boot order means it may re-image on next hard reset.

**Terraform discrepancy:** Terraform vars specified VMID=200, 4 GB RAM, 32 GB disk. Actual VM is VMID=100, 6.9 GB RAM, 108 GB disk — manually provisioned outside of Terraform.

---

## VM 101 — home-router (OPNsense)

| Property | Value |
|---|---|
| VMID | 101 |
| Status | running |
| vCPU | 2 |
| RAM | 4.2 GB used / 6.1 GB max |
| Disk | 32 GB |
| Uptime | ~10 minutes at time of snapshot |
| net0 (WAN) | vmbr0, MAC: BC:24:11:2B:01:8B |
| net1 (LAN) | vmbr1, tap101i1 |
| WAN IP | 192.168.1.101 (confirmed in Proxmox ARP) |
| LAN IP | 10.0.0.1 (expected, unreachable from Proxmox host) |
| LAN tap RX | 412 MB received |
| LAN tap TX | 62 MB sent |
| API auth | 401 Unauthorized — credentials stale or regenerated |

**Status Assessment:** OPNsense is up and routing. WAN reachable. LAN interface is active (high RX byte count on tap101i1 indicates internal routing traffic). However, 10.0.0.1 is unreachable from the Proxmox host because the host has no route to 10.0.0.0/24 — this is expected unless a static route is added on the host or accessed via WAN-side NAT. The 401 API error means the Terraform API key for OPNsense configuration is invalid and must be regenerated in the OPNsense web UI.

---

## TP-Link Omada SG2008 — Current State & VLAN Setup

### Current State

| Property | Value |
|---|---|
| Model | TP-Link TL-SG2008 (Omada Smart Switch, 8-port GbE) |
| Connected to | enx1c860b363f63 (Proxmox physical LAN NIC) via uplink port (port 8) |
| Management IP | Not yet configured — defaults to 192.168.0.1 |
| Target management IP | 10.0.0.2 (static DHCP lease from OPNsense) |
| VLAN config | Pending — 802.1Q VLAN 10 not yet created |
| Physical nodes connected | None yet (CP2, CP3, Workers 1-3 planned) |

**Design:** Single VLAN 10 (`homelab-lan`, 10.0.0.0/24) managed by OPNsense. The switch carries VLAN 10 tagged on the uplink to Proxmox and untagged on device ports 1–7. OPNsense is the DHCP and routing authority for the subnet.

---

### VLAN Setup Directions

**Goal:** Put all homelab devices into VLAN 10 (10.0.0.0/24). OPNsense handles DHCP and routing. The switch is a Layer 2 device only.

#### Step 1 — Proxmox: Enable VLAN-aware on vmbr1

In the Proxmox UI:
```
Proxmox UI → System → Network → vmbr1 → Edit → check "VLAN aware" → Apply
```

Or via shell — edit `/etc/network/interfaces`, add `bridge-vlan-aware yes` to the vmbr1 stanza, then reload:
```bash
# /etc/network/interfaces — vmbr1 stanza
iface vmbr1 inet manual
    bridge-ports enx1c860b363f63 fwpr100p0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes   # add this line

# Apply without reboot
ifreload -a
```

#### Step 2 — OPNsense: Create VLAN 10 on LAN interface

```
Interfaces → Other Types → VLAN → Add
  Parent interface: vtnet1   (the LAN NIC, check actual name in Interfaces → Assignments)
  VLAN tag:        10
  Description:     homelab-lan
  Save
```

#### Step 3 — OPNsense: Assign and configure VLAN 10 interface

```
Interfaces → Assignments → add vtnet1_vlan10 → assign as OPT1
  Rename description: LAN10
  IPv4 Configuration Type: Static IPv4
  IPv4 Address: 10.0.0.1 / 24
  Enable interface: ✓
  Save → Apply changes
```

> **WARNING — Do NOT reassign the existing LAN interface to vtnet1_vlan10 in a single step.**
>
> If you change `Interfaces → Assignments → LAN` to use `vtnet1_vlan10` before the Proxmox bridge is
> VLAN-aware, you will be **immediately locked out**: the bridge passes frames untagged, OPNsense's
> VLAN subinterface drops all of them, LAN goes dark, and the anti-lockout rule stops working.
> WAN-side WebGUI access is also blocked by default — you will be unreachable from both sides.
>
> **For single-VLAN setups:** The simpler and safer approach is Option A — leave `LAN = vtnet1`
> (untagged) and configure VLAN 10 as a switch-internal concept only. No Proxmox changes needed.
>
> **For multi-VLAN setups (Option B / trunk mode):** You must enable VLAN-aware on vmbr1 (Step 1)
> *first*, then create the VLAN subinterface as a new OPT interface, verify it works, and only then
> transition away from the original LAN assignment. Never cut over LAN and the bridge in the same step.
>
> If you are already locked out, see **`docs/opnsense-vlan-setup.md`** for console-based recovery
> via the Proxmox noVNC console and the correct setup procedure for both approaches.

#### Step 4 — OPNsense: Enable DHCP on VLAN 10

```
Services → DHCPv4 → [LAN10] → Enable
  Range:           10.0.0.100 – 10.0.0.200
  DNS server:      10.0.0.1 (OPNsense)
  Gateway:         10.0.0.1

  Static Mappings → Add:
    MAC:  (SG2008 MAC — printed on switch label)
    IP:   10.0.0.2
    Name: sg2008-switch
```

#### Step 5 — SG2008: Configure 802.1Q VLAN

Log into the SG2008 web UI. Default address before reconfiguration: `http://192.168.0.1` (admin / admin).

```
L2 FEATURES → 802.1Q VLAN → VLAN Config:
  Add VLAN:
    VLAN ID:   10
    Name:      homelab-lan

  Port membership for VLAN 10:
    Port 8 (uplink to Proxmox):  Tagged    — trunk carrying VLAN 10 tag to OPNsense
    Ports 1–7 (device ports):    Untagged  — devices receive untagged frames

L2 FEATURES → 802.1Q VLAN → Port Config:
  Port 8:   PVID = 1   (uplink — native VLAN stays 1 for management until Step 6)
  Ports 1–7: PVID = 10  (devices default to VLAN 10)
```

#### Step 6 — SG2008: Set management VLAN and static IP

```
SYSTEM → System IP:
  Management VLAN:  10
  IP Address:       10.0.0.2
  Subnet Mask:      255.255.255.0
  Gateway:          10.0.0.1
  Save
```

After saving, the switch will drop the 192.168.0.x management address. Reconnect at `http://10.0.0.2` from any device on the 10.0.0.0/24 network.

Update Port 8 PVID to 10 as well if all management traffic should be in VLAN 10.

#### Step 7 — OPNsense: Firewall (informational)

By default, OPNsense's LAN/LAN10 rule allows all outbound traffic. No extra rule is needed — any device on 10.0.0.0/24 can reach the switch management UI at 10.0.0.2. If you later want to restrict management access to specific hosts, add a firewall rule on LAN10 blocking TCP port 80/443 to 10.0.0.2 from unauthorized sources.

---

## Network Connectivity Matrix

| Source | Destination | Reachable | Notes |
|---|---|---|---|
| Proxmox host | Main router (192.168.1.1) | Yes | Default route via WAN NIC |
| Proxmox host | OPNsense WAN (192.168.1.101) | Yes | Same subnet |
| Proxmox host | OPNsense LAN (10.0.0.1) | No | Host has no route to 10.0.0.0/24 |
| Proxmox host | Talos CP1 (10.0.0.10) | No | Same — no LAN route |
| OPNsense WAN | Internet | Yes (assumed) | WAN IP assigned from main router |
| OPNsense LAN | Talos CP1 | Unknown | DHCP may not be responding to CP1 MAC |
| Talos CP1 | OPNsense LAN | Unknown | No confirmed IP lease |
| Physical LAN NIC | Physical nodes | Pending | No physical nodes connected yet |

---

## Issues & Diagnosis

### 1. Talos CP1 — No IP Address
- **Symptom:** VM 100 not in Proxmox ARP table; only 35 RX packets
- **Likely cause:** OPNsense DHCP not issuing a lease for MAC `BC:24:11:FC:76:0A`, or Talos maintenance mode is up but no route from Proxmox host to reach it
- **Check:** OPNsense web UI → Services → DHCPv4 → Leases (look for CP1 MAC or any `10.0.0.x` entry)

### 2. OPNsense LAN Unreachable from Proxmox Host
- **Symptom:** `ping 10.0.0.1` fails from Proxmox host
- **Root cause:** Proxmox host has no route to 10.0.0.0/24. The host sits on vmbr1 but routes all traffic via vmbr0/WAN by default
- **Fix options:**
  - Add static route on Proxmox host: `ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1` (temporary)
  - Or SSH into OPNsense directly on WAN side and manage from there

### 3. OPNsense API Auth Failing (401)
- **Symptom:** `curl https://192.168.1.101/api/...` returns 401
- **Root cause:** API key/secret in Terraform vars (`terraform.tfvars`) is stale — OPNsense may have regenerated credentials
- **Fix:** Log into OPNsense web UI → System → Access → Users → API keys → regenerate and update `terraform.tfvars`

### 4. Terraform State Mismatch
- **Symptom:** VM 100 (talos-cp-1) exists with different VMID, RAM, and disk than Terraform configuration specifies
- **Root cause:** VM was manually created or modified outside of Terraform
- **Risk:** Running `terraform apply` may attempt to destroy/recreate VM 100 or create a duplicate VM 200
- **Fix:** Import the existing VM into Terraform state before applying: `terraform import proxmox_virtual_environment_vm.talos_cp1 home/100`

### 5. Talos Cluster Not Bootstrapped
- **Symptom:** `talosconfig` has no endpoints or cluster context
- **Prerequisite:** Talos CP1 needs a confirmed IP before `talosctl bootstrap` can be run
- **Blocked by:** Issues 1 and 2 above

### 6. Physical Nodes Not Yet Deployed
- **Scope:** CP2 (10.0.0.11), CP3 (10.0.0.12), Workers 1-3 (10.0.0.20-22) are planned but not connected or provisioned

---

## Recommended Next Steps

1. **Verify OPNsense DHCP** — Access OPNsense web UI at `https://192.168.1.101` from a machine on the WAN network. Check DHCP leases for CP1 MAC `BC:24:11:FC:76:0A`. If no lease, manually assign a static mapping for that MAC → 10.0.0.10.

2. **Add host route on Proxmox** (temporary) — `ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1` to be able to reach LAN devices from the Proxmox host for debugging.

3. **Regenerate OPNsense API credentials** — Update `terraform/terraform.tfvars` with fresh API key/secret.

4. **Import Talos CP1 into Terraform state** — Run `terraform import proxmox_virtual_environment_vm.talos_cp1 home/100` to reconcile the state mismatch before next `terraform apply`.

5. **Detach ISO from Talos CP1** — Once CP1 has a confirmed IP and boots from disk, detach `talos-metal-amd64.iso` to prevent accidental re-imaging on reboot (`qm set 100 --ide2 none`).

6. **Bootstrap Talos cluster** — Once CP1 has an IP, follow `docs/talos-setup-guide.md` to run `talosctl bootstrap` and generate kubeconfig.

7. **Configure SG2008 VLAN** — Follow the VLAN Setup Directions above (Steps 1–6) to bring up VLAN 10 on the switch, set the management IP to 10.0.0.2, and add a static DHCP lease in OPNsense for the switch MAC.

8. **Deploy physical nodes** — Connect CP2, CP3, and Workers to LAN switch ports 1–7 and provision via PXE or manual Talos ISO boot.

---

## References & Further Reading

### Similar Homelab Guides

- [Eric Daly's Kubernetes Homelab Series — Talos on Proxmox](https://blog.dalydays.com/post/kubernetes-homelab-series-part-1-talos-linux-proxmox/)
- [Talos on Proxmox with OpenTofu (IaC) — stonegarden.dev](https://blog.stonegarden.dev/articles/2024/08/talos-proxmox-tofu/)
- [HA Kubernetes on Proxmox with Terraform + Talos — itguyjournals.com](https://www.itguyjournals.com/deploying-ha-kubernetes-cluster-with-proxmox-terraform-and-talos-os/)
- [VLAN from Scratch — OPNsense + Proxmox + Switch — koromatech.com](https://koromatech.com/vlan-setup-from-scratch-opnsense-proxmox-switch-complete-guide/)
- [Talos Cluster on Proxmox with Terraform — olav.ninja](https://olav.ninja/talos-cluster-on-proxmox-with-terraform)
- [IoT VLAN with OPNsense + TP-Link Omada — gaelanlloyd.com](https://www.gaelanlloyd.com/blog/iot-vlan-opnsense-omada-ipv6/)
- [OPNsense + Proxmox VLAN trunk setup — Proxmox forum](https://forum.proxmox.com/threads/help-with-proxmox-trunk-port-setup-%E2%80%93-letting-opnsense-handle-vlans-dhcp-etc.167426/)

### Official Documentation

- [Talos Linux — Getting Started](https://www.talos.dev/v1.10/introduction/getting-started/)
- [Talos Linux on Proxmox](https://www.talos.dev/v1.10/talos-guides/install/virtualized-platforms/proxmox/)
- [OPNsense — VLAN and LAGG setup](https://docs.opnsense.org/manual/how-tos/vlan_and_lagg.html)
- [Proxmox — Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)
- [TP-Link — 802.1Q VLAN on Omada switches with 3rd-party router](https://www.tp-link.com/us/support/faq/4084/)
- [TP-Link — 802.1Q VLAN on Smart/Managed switches](https://www.tp-link.com/us/support/faq/2149/)
