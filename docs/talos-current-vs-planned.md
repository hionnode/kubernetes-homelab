# Talos: Current State vs Planned — Findings & Action Items

**Date:** 2026-03-12
**Purpose:** Gap analysis between the current Talos deployment state and the planned end-state, with actionable items to close each gap.

---

## Executive Summary

The homelab project targets a 6-node hybrid Talos Kubernetes cluster (1 VM + 5 physical nodes) with full GitOps, observability, and HA. Currently, only the first control plane VM exists — and it is non-functional due to networking and Terraform state issues. The cluster has never been bootstrapped. Everything beyond CP1 (physical nodes, ArgoCD, observability, MetalLB) is documentation-only with no deployment.

---

## Current State vs Planned

### 1. Network Infrastructure

| Item | Planned | Current | Gap |
|------|---------|---------|-----|
| OPNsense VM | Running, LAN gateway at 10.0.0.1 | Running (VM 101), WAN reachable at 192.168.1.101 | LAN (10.0.0.1) unreachable from Proxmox host — no route on host |
| OPNsense API | Terraform-managed via API key | 401 Unauthorized — credentials stale | API key must be regenerated |
| DHCP on LAN | Serving 10.0.0.x leases to all nodes | Unknown — CP1 has no lease | Must verify DHCP is active and serving leases |
| VLAN 10 on OPNsense | VLAN 10 (homelab-lan) configured | Not created | Follow `docs/opnsense-vlan-setup.md` |
| TP-Link SG2008 switch | 802.1Q VLAN 10, mgmt IP 10.0.0.2 | Defaults (192.168.0.1), no VLAN config | Follow `docs/switch-setup-guide.md` |
| Proxmox vmbr1 | VLAN-aware bridge to LAN | Bridge exists, NOT VLAN-aware | Enable `bridge-vlan-aware yes` on vmbr1 |
| Proxmox host route to LAN | Host can reach 10.0.0.0/24 | No route exists | Add static route or access LAN via OPNsense WAN |

### 2. Talos Control Plane

| Item | Planned | Current | Gap |
|------|---------|---------|-----|
| talos-cp-1 (VM) | VM 200, 4 GB RAM, 32 GB disk, Terraform-managed | VM 100, 6.9 GB RAM, 108 GB disk, manually created | Terraform state mismatch — must import or recreate |
| CP1 IP address | 10.0.0.10 via DHCP reservation | No IP assigned (no DHCP lease) | Fix DHCP, add static mapping for MAC `BC:24:11:FC:76:0A` |
| CP1 boot config | Boot from disk, ISO detached | ISO still attached, booting from ISO | Detach ISO after config is applied |
| CP1 Talos config | Applied via Terraform `talos_machine_configuration_apply` | Never applied — no network connectivity | Blocked by networking issues |
| talos-cp-2 (physical) | Running at 10.0.0.11 | Not deployed | Hardware not connected |
| talos-cp-3 (physical) | Running at 10.0.0.12 | Not deployed | Hardware not connected |
| Cluster bootstrap | `talosctl bootstrap` completed, etcd running | Never bootstrapped | Blocked by CP1 having no IP |
| VIP (10.0.0.5) | Active, shared across control planes | Not configured | Requires at least one working CP node |
| talosconfig | Valid endpoints and cluster context | Empty file (25 bytes at `~/.talos/config`) | Generated after bootstrap |

### 3. Worker Nodes

| Item | Planned | Current | Gap |
|------|---------|---------|-----|
| talos-worker-1 | Running at 10.0.0.20 | Not deployed | Hardware not connected |
| talos-worker-2 | Running at 10.0.0.21 | Not deployed | Hardware not connected |
| talos-worker-3 | Running at 10.0.0.22 | Not deployed | Hardware not connected |
| Worker config | Applied via `talosctl apply-config` | Not generated | Blocked by cluster bootstrap |

### 4. Kubernetes Platform Services

| Item | Planned | Current | Gap |
|------|---------|---------|-----|
| CNI (Cilium) | Installed in kube-system | Not installed | Requires running cluster |
| MetalLB | IP pool 10.0.0.50-99 | Not installed | Requires running cluster |
| ArgoCD | GitOps deployment pipeline | Documentation only (`docs/argocd-setup-guide.md`) | Requires running cluster |
| Observability | Grafana Cloud + in-cluster SigNoz/Prometheus | Documentation only (`docs/observability-guide.md`) | Requires running cluster |

### 5. Terraform & IaC

| Item | Planned | Current | Gap |
|------|---------|---------|-----|
| Talos provider | Manages secrets, configs, bootstrap | Resources defined in `cluster_talos.tf` but never applied successfully | Blocked by networking |
| OPNsense provider | Manages firewall rules, DHCP | Resources defined in `config_opnsense.tf` but API auth fails (401) | Regenerate API credentials |
| S3 backend | Remote state in AWS | Configured | Working |
| CP1 VM resource | `proxmox_virtual_environment_vm.talos_cp1` | State doesn't match actual VM (VMID, RAM, disk differ) | Import existing VM or destroy and let Terraform recreate |

### 6. Automation Scripts

| Item | Planned | Current | Gap |
|------|---------|---------|-----|
| `scripts/03-setup-talos.sh` | Automated Talos setup | Template stub — prints planned steps only | Not implemented (Terraform approach preferred) |

---

## Critical Blockers (Ordered)

These must be resolved sequentially — each one unblocks the next:

### Blocker 1: OPNsense LAN / DHCP not serving CP1
- **Impact:** CP1 has no IP → cannot apply Talos config → cannot bootstrap cluster → everything downstream blocked
- **Root cause:** Either DHCP not running on LAN interface, or DHCP not mapped to CP1's MAC
- **Action:**
  - [ ] Access OPNsense web UI at `https://192.168.1.101`
  - [ ] Verify LAN interface is up and assigned 10.0.0.1/24
  - [ ] Verify DHCPv4 is enabled on LAN
  - [ ] Add static DHCP mapping: MAC `BC:24:11:FC:76:0A` → IP `10.0.0.10` → hostname `talos-cp-1`
  - [ ] Reboot CP1 VM and confirm it receives an IP

### Blocker 2: Proxmox host cannot reach LAN subnet
- **Impact:** Cannot manage or debug LAN devices from the Proxmox host
- **Action:**
  - [ ] Add temporary route: `ip route add 10.0.0.0/24 via 10.0.0.1 dev vmbr1`
  - [ ] Make permanent by adding to `/etc/network/interfaces` if needed
  - [ ] Verify: `ping 10.0.0.1` and `ping 10.0.0.10`

### Blocker 3: OPNsense API credentials stale
- **Impact:** Terraform cannot manage OPNsense resources (firewall rules, DHCP config)
- **Action:**
  - [ ] Log into OPNsense web UI → System → Access → Users → API keys
  - [ ] Generate new API key/secret pair
  - [ ] Update `terraform/terraform.tfvars` with new credentials

### Blocker 4: Terraform state mismatch for CP1 VM
- **Impact:** `terraform apply` may destroy the existing VM or create a duplicate
- **Action:**
  - [ ] Decide: import existing VM 100 or destroy it and let Terraform create VM 200
  - [ ] If importing: `terraform import proxmox_virtual_environment_vm.talos_cp1 home/100`
  - [ ] If recreating: update Terraform vars to match desired spec, destroy VM 100 manually, run `terraform apply`
  - [ ] Reconcile RAM (4 GB vs 6.9 GB) and disk (32 GB vs 108 GB) decisions

---

## Action Plan (Priority Order)

### Phase A: Fix Networking (Unblocks Everything)
1. [ ] Fix OPNsense DHCP — verify LAN, add CP1 static mapping (Blocker 1)
2. [ ] Add Proxmox host route to 10.0.0.0/24 (Blocker 2)
3. [ ] Confirm CP1 gets IP 10.0.0.10 — `ping 10.0.0.10` from Proxmox host
4. [ ] Regenerate OPNsense API credentials and update tfvars (Blocker 3)

### Phase B: Get CP1 Operational
5. [ ] Resolve Terraform state mismatch for CP1 VM (Blocker 4)
6. [ ] Run `terraform apply` — should apply Talos machine config to CP1
7. [ ] Detach ISO from CP1: `qm set 100 --ide2 none` (or 200 if recreated)
8. [ ] Verify CP1 boots from disk with Talos config applied

### Phase C: Bootstrap Cluster
9. [ ] `talosctl bootstrap --nodes 10.0.0.10`
10. [ ] Verify etcd is running: `talosctl etcd members`
11. [ ] Generate kubeconfig: `talosctl kubeconfig -f ~/.kube/config`
12. [ ] Verify: `kubectl get nodes` — should show 1 control plane node

### Phase D: Network Hardening (VLAN)
13. [ ] Enable VLAN-aware on Proxmox vmbr1
14. [ ] Configure VLAN 10 on OPNsense (per `docs/opnsense-vlan-setup.md`)
15. [ ] Configure 802.1Q VLAN on SG2008 switch (per `docs/switch-setup-guide.md`)
16. [ ] Verify end-to-end VLAN connectivity

### Phase E: Scale to Full Cluster
17. [ ] Connect physical node CP2, boot Talos USB, apply config → 10.0.0.11
18. [ ] Connect physical node CP3, boot Talos USB, apply config → 10.0.0.12
19. [ ] Verify 3-node etcd + VIP failover
20. [ ] Connect workers 1-3, apply worker configs → 10.0.0.20-22
21. [ ] Label worker nodes

### Phase F: Platform Services
22. [ ] Install Cilium CNI
23. [ ] Install MetalLB with pool 10.0.0.50-99
24. [ ] Deploy ArgoCD (per `docs/argocd-setup-guide.md`)
25. [ ] Set up observability stack (per `docs/observability-guide.md`)

---

## Decisions Needed

| # | Decision | Options | Notes |
|---|----------|---------|-------|
| 1 | Keep VM 100 or recreate as VM 200? | Import existing / Destroy and recreate | VM 100 has 108 GB disk and 6.9 GB RAM vs planned 32 GB / 4 GB |
| 2 | VLAN setup: single-VLAN (Option A) or trunk mode (Option B)? | Option A is simpler; Option B needed for future multi-VLAN | See warning in `docs/homelab-current-state.md` |
| 3 | Keep `allowSchedulingOnControlPlanes: true`? | Yes (use CP for workloads) / No (dedicated workers only) | Currently true in Terraform config, false in setup guide patch |
| 4 | Talos version upgrade? | Stay on v1.9.0 / Upgrade to latest | Current config targets v1.9.0, latest is v1.10.x |
| 5 | Automate CP2/CP3 in Terraform? | Yes (add resources) / No (manual via talosctl) | Only CP1 is currently in Terraform |

---

## Reference Files

| File | Purpose |
|------|---------|
| `terraform/cluster_talos.tf` | Talos cluster Terraform resources (CP1 only) |
| `terraform/variables.tf` | All Talos-related variables and defaults |
| `terraform/outputs.tf` | Talos outputs (talosconfig, MAC, endpoint) |
| `docs/talos-setup-guide.md` | Full manual bootstrap procedure (all 6 nodes) |
| `docs/talos-management-handbook.md` | Day-2 operations guide |
| `docs/talos-cp1-terraform-guide.md` | Blog-ready Terraform deployment guide |
| `docs/homelab-current-state.md` | Infrastructure snapshot as of 2026-03-08 |
| `docs/opnsense-vlan-setup.md` | VLAN configuration procedure |
| `docs/switch-setup-guide.md` | TP-Link SG2008 VLAN setup |
| `docs/implementation_plan.md` | Original phase-based plan |
| `docs/task.md` | Phase completion checklist |
