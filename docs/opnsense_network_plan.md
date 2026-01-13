# OPNsense Dual-NIC Gateway Implementation

## Network Analysis

**Proxmox Host (192.168.1.110):**
- `enp2s0` → Connected to main router (192.168.1.1) - **WAN**
- `enx1c860b363f63` → Connected to TP-Link switch - **LAN** (currently DOWN)
- `vmbr0` → Bridge with `enp2s0`, hosts Proxmox management

**Target Architecture:**
```
Internet
   │
Main Router (192.168.1.1)
   │
   ├─ Proxmox Management (192.168.1.110)
   │
   └─ enp2s0 (vmbr0) → OPNsense WAN (vtnet0)
                             │
                        OPNsense VM
                             │
              enx1c860b363f63 (vmbr1) ← OPNsense LAN (vtnet1) [10.0.0.1/24]
                                                │
                                          TP-Link Switch
                                                │
                                        ├─ Physical Talos Nodes
                                        └─ Talos VM (Proxmox)
```

---

## Implementation Steps

### Phase 1: Proxmox Bridge Configuration (Ansible)

**File**: `ansible/playbooks/configure_proxmox_network.yml`

1. **Bring up second interface**
2. **Create vmbr1 bridge**
3. **Add enx1c860b363f63 to vmbr1**
4. **Apply configuration**

> **Note**: This requires writing to `/etc/network/interfaces` and running `ifreload -a`

---

### Phase 2: Update OPNsense VM (Terraform)

**File**: `terraform/vm_opnsense.tf`

Add second network device:
```hcl
network_device {
  bridge = "vmbr0"  # WAN
}

network_device {
  bridge = "vmbr1"  # LAN
}
```

**Run**: `terraform apply`

---

### Phase 3: OPNsense Interface Assignment (Manual)

Via Proxmox Console:
1. Assign interfaces:
   - `vtnet0` → WAN
   - `vtnet1` → LAN
2. Configure WAN:
   - Type: DHCP (from 192.168.1.1)
3. Configure LAN:
   - IP: 10.0.0.1
   - Subnet: 24 (255.255.255.0)
4. Enable DHCP on LAN:
   - Range: 10.0.0.100 - 10.0.0.200

---

### Phase 4: OPNsense NAT & Firewall (Ansible)

Update `ansible/playbooks/configure_opnsense.yml`:
1. Configure NAT rule (WAN outbound)
2. Configure firewall rules:
   - Allow LAN → WAN
   - Block WAN → LAN (except established)
3. Update VLAN 10 parent to LAN interface

---

### Phase 5: Future Talos VM Update

**File**: `terraform/cluster_talos.tf`

Change Talos VM network from `vmbr0` to `vmbr1` so it gets IP from OPNsense.

---

## Execution Order

1. ✅ Create Proxmox network playbook
2. ✅ Run playbook to configure vmbr1
3. ✅ Update Terraform for OPNsense VM
4. ✅ Apply Terraform changes
5. ⚠️ Manual: Configure OPNsense interfaces via console
6. ✅ Update Ansible OPNsense playbook for NAT/Firewall
7. ✅ Run Ansible playbook

---

## User Decisions

> [!IMPORTANT]
> **Proxmox Management Access**: After this change, Proxmox (192.168.1.110) stays on the main router network. You'll still access it from your laptop as usual. The TP-Link switch devices will be on the new 10.0.0.0/24 network behind OPNsense.

**Proceed?**
