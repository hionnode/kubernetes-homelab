# Homelab Setup Walkthrough

## Overview

Built a Proxmox-based homelab with OPNsense as network gateway and foundation for a Talos Kubernetes cluster.

---

## Phase 1: OPNsense VM Deployment (Terraform)

### Infrastructure Created

**Files:**
- [terraform/vm_opnsense.tf](file:///Users/chinmay/code/homelab/kubernetes-homelab/terraform/vm_opnsense.tf) - VM definition with dual NICs
- [terraform/iso.tf](file:///Users/chinmay/code/homelab/kubernetes-homelab/terraform/iso.tf) - Automated ISO download with bz2 decompression
- [terraform/providers.tf](file:///Users/chinmay/code/homelab/kubernetes-homelab/terraform/providers.tf) - Proxmox, OPNsense, Talos providers
- [terraform/versions.tf](file:///Users/chinmay/code/homelab/kubernetes-homelab/terraform/versions.tf) - Provider versions and S3 backend

**Resources Deployed:**
- OPNsense VM (ID: 100)
  - CPU: 2 cores
  - RAM: 2048MB
  - Disk: 16GB
  - Network: Dual NICs (vmbr0 WAN, vmbr1 LAN)
- OPNsense ISO auto-downloaded and decompressed on Proxmox

### Key Fixes
- Boot order configuration (CDROM priority)
- ISO decompression support (`bz2` → `.iso`)
- Explicit `file_name` for Proxmox upload compatibility

---

## Phase 2: Configuration Management (Ansible)

### Pivot Decision
Abandoned `browningluke/opnsense` Terraform provider due to:
- Lack of interface assignment support
- Pre-stability limitations

Adopted `ansibleguy.opnsense` + `puzzle.opnsense` Ansible collections for runtime configuration.

### Ansible Setup

**Files:**
- [ansible/requirements.yml](file:///Users/chinmay/code/homelab/kubernetes-homelab/ansible/requirements.yml)
- [ansible/inventory/hosts.ini.example](file:///Users/chinmay/code/homelab/kubernetes-homelab/ansible/inventory/hosts.ini.example)
- [ansible/playbooks/configure_opnsense.yml](file:///Users/chinmay/code/homelab/kubernetes-homelab/ansible/playbooks/configure_opnsense.yml)

**Collections Installed:**
- `ansibleguy.opnsense` - VLAN, DHCP, firewall management
- `puzzle.opnsense` - Interface assignments

### Dependency Resolution

**Problem:** `ModuleNotFoundError: No module named 'httpx'`

**Root Cause:** Ansible installed via `pipx` (isolated environment). Standard `pip install` targeted wrong Python.

**Solution:**
```bash
pipx inject ansible httpx
```

**Additional Fix:** Removed `ansible_python_interpreter` from inventory to use pipx's Python.

---

## Phase 3: Network Architecture

### Goal
OPNsense as gateway for all devices on TP-Link switch, routing to internet via main router.

### Hardware Topology
```
Internet → Main Router (192.168.1.1)
              │
              └─ Proxmox Host (192.168.1.110)
                    ├─ enp2s0 (vmbr0) → OPNsense WAN
                    └─ enx1c860b363f63 (vmbr1) → OPNsense LAN
                                                      │
                                                TP-Link Switch
                                                      │
                                              ├─ Physical Talos Nodes
                                              └─ Talos VM (future)
```

### Proxmox Bridge Configuration

**Manual Commands Executed:**
```bash
# Add vmbr1 to /etc/network/interfaces
ssh root@192.168.1.110 "cat >> /etc/network/interfaces << 'EOF'
iface enx1c860b363f63 inet manual
auto vmbr1
iface vmbr1 inet manual
        bridge-ports enx1c860b363f63
        bridge-stp off
        bridge-fd 0
EOF
"

# Apply configuration
ssh root@192.168.1.110 "ip link set enx1c860b363f63 up && ifreload -a"
```

**Verification:**
```bash
ssh root@192.168.1.110 "ip link show vmbr1"
# Output: vmbr1: <BROADCAST,MULTICAST,UP,LOWER_UP>
```

### OPNsense VM Network Update

**Terraform Change:**
```diff
+ # WAN Interface (Internet)
  network_device {
-   bridge = var.network_bridge
+   bridge = "vmbr0"
  }
+ 
+ # LAN Interface (Switch)
+ network_device {
+   bridge = "vmbr1"
+ }
```

**Status:** Currently applying (`terraform apply` in progress)

---

## Troubleshooting Log

### Issue 1: Terraform Auth Error
**Error:** `Unable to create Proxmox VE API credentials`  
**Cause:** Missing/incorrect `terraform.tfvars`  
**Fix:** User populated correct credentials

### Issue 2: ISO Download Hostname Lookup Failed
**Error:** `hostname lookup 'pve' failed`  
**Cause:** `proxmox_node` mismatch  
**Fix:** User verified correct node name in GUI

### Issue 3: Wrong File Extension
**Error:** `HTTP 400 ... filename: wrong file extension`  
**Cause:** Proxmox rejected `.bz2` as ISO  
**Fix:** Added `file_name = "opnsense-25.7.iso"` and `decompression_algorithm = "bz2"`

### Issue 4: Boot Failure
**Error:** VM booted to iPXE instead of ISO  
**Cause:** CDROM disabled, wrong boot order  
**Fix:** Added `enabled = true` to CDROM and `boot_order = ["ide3", "scsi0"]`

### Issue 5: Ansible Module Missing
**Error:** `couldn't resolve module/action 'ansibleguy.opnsense.interface'`  
**Cause:** Module doesn't exist (collection lacks interface assignment)  
**Fix:** Added `puzzle.opnsense` for `interfaces_assignments`

### Issue 6: Python Module Missing (httpx)
**Error:** `ModuleNotFoundError: No module named 'httpx'`  
**Cause:** Ansible in pipx venv, `pip install` targeted wrong Python  
**Fix:** `pipx inject ansible httpx`

### Issue 7: Invalid Firewall Dict
**Error:** `Host ... is neither a valid IP nor Domain-Name`  
**Cause:** Used `url: https://...` instead of `ip: ...`  
**Fix:** Updated playbook to strip schema and use `ip` key

---

## Git Commits

- `feat: complete opnsense terraform setup including auto-iso and vlan config`
- `feat: scaffold ansible structure for opnsense config`
- `feat: wip ansible opnsense configuration (dependencies installed)`

---

## Next Steps

1. ⏳ Wait for Terraform to finish adding second NIC
2. 🔧 Start OPNsense VM and configure interfaces via console
3. 📋 Update Ansible playbook for NAT and firewall rules
4. ✅ Verify LAN devices get 10.0.0.x IPs from OPNsense
5. 🚀 Begin Talos cluster bootstrap

---

## Lessons Learned

1. **Terraform is slow for VM modifications** - Use `qm` commands for quick changes
2. **Pipx isolation breaks dependencies** - Must inject packages into Ansible venv
3. **Proxmox provider quirks** - ISO filenames must match expected extension
4. **Community providers have gaps** - Terraform OPNsense provider incomplete; Ansible more mature
