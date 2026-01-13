# Manual Configuration Guide

Complete manual setup guide for Proxmox and OPNsense in homelab environment.

---

## Proxmox Configuration

### 1. Network Bridges Setup

#### Verify Physical Interfaces
```bash
ip link show
```

Expected interfaces:
- `enp2s0` - WAN (internet connection)
- `enx1c860b363f63` - LAN (TP-Link switch)

#### Configure vmbr0 (WAN Bridge)

Should already exist from Proxmox installation. Verify in `/etc/network/interfaces`:

```bash
auto vmbr0
iface vmbr0 inet static
        address 192.168.1.110/24
        gateway 192.168.1.1
        bridge-ports enp2s0
        bridge-stp off
        bridge-fd 0
```

#### Create vmbr1 (LAN Bridge)

Edit `/etc/network/interfaces`:

```bash
iface enx1c860b363f63 inet manual

auto vmbr1
iface vmbr1 inet manual
        bridge-ports enx1c860b363f63
        bridge-stp off
        bridge-fd 0
        comment LAN Bridge for OPNsense
```

Apply config:
```bash
ip link set enx1c860b363f63 up
ifreload -a
```

Verify:
```bash
ip link show vmbr1
# Should show: state UP
```

### 2. OPNsense VM Configuration

#### VM Settings (ID 101)

**Hardware → Network Devices:**

1. **net0** (WAN)
   ```
   Bridge: vmbr0
   Model: VirtIO
   ```

2. **net1** (LAN)
   ```
   Bridge: vmbr1
   Model: VirtIO
   ```

**Via CLI:**
```bash
# Stop VM first
qm stop 101

# Configure network interfaces
qm set 101 -net0 virtio,bridge=vmbr0
qm set 101 -net1 virtio,bridge=vmbr1

# Start VM
qm start 101
```

#### Boot Order
Set CDROM first for initial install, then disk after installation.

```bash
qm set 101 -boot order=scsi0
```

---

## OPNsense Configuration

### 1. Initial Console Setup

Access VM console via Proxmox GUI: **VM 101 → Console**

#### Interface Assignment

When prompted:
```
1) Assign Interfaces

Do you want to set up VLANs? → n

WAN interface: vtnet0
LAN interface: vtnet1
Optional interfaces: (press Enter)

Proceed? → y
```

### 2. WAN Interface Configuration

```
2) Set interface(s) IP address

Select: 1 (WAN - vtnet0)

Configure IPv4 via DHCP? → y
Configure IPv6 via DHCP? → n
Revert to HTTP? → n
```

**Expected Result:** WAN gets IP from main router (192.168.1.x)

### 3. LAN Interface Configuration

```
2) Set interface(s) IP address

Select: 2 (LAN - vtnet1)

Configure IPv4 via DHCP? → n
IPv4 address: 10.0.0.1
Subnet bit count: 24

Upstream gateway: (press Enter - none)
Configure IPv6: n

Enable DHCP server on LAN? → y
Start address: 10.0.0.100
End address: 10.0.0.200
```

**Expected Result:** LAN configured as 10.0.0.1/24 with DHCP

### 4. Access Web GUI

From your laptop (still on 192.168.1.x network):

```
URL: https://192.168.1.XXX
(Check console for WAN IP if unknown)

Default credentials:
Username: root
Password: opnsense
```

### 5. Web GUI Initial Configuration

#### System: Settings: Administration

1. **Set new root password** (recommended)
2. **Enable Secure Shell:**
   - System → Settings → Administration
   - Secure Shell Server: ✓ Enabled
   - Root Login: ✓ Permit root user login

#### System: Access: Users

Generate API credentials for automation:

1. Edit **root** user (or create new API user)
2. Scroll to **API keys** section
3. Click **+** to generate new key
4. **Save** key and secret immediately (cannot view again)

**Store credentials securely:**
```bash
# In terraform.tfvars or environment
opnsense_api_key="..."
opnsense_api_secret="..."
```

### 6. Firewall Configuration

#### Interfaces: Assignments

Verify interface mapping:
- WAN → vtnet0 (192.168.1.x)
- LAN → vtnet1 (10.0.0.1)

#### Firewall: NAT: Outbound

Set to **Automatic outbound NAT**:
1. Firewall → NAT → Outbound
2. Mode: **Automatic outbound NAT rule generation**
3. Save

#### Firewall: Rules: LAN

Default LAN rules should allow all. Verify:

1. Firewall → Rules → LAN
2. Should see rules allowing LAN to any

If missing, add rule:
- Action: Pass
- Interface: LAN
- Source: LAN net
- Destination: any
- Description: "Allow LAN to any"

#### Firewall: Rules: WAN

Default: **Block all** (correct for security)

### 7. DHCP Server Configuration

Already configured during console setup. Verify:

**Services → DHCPv4 → [LAN]**
- Enable: ✓
- Range: 10.0.0.100 - 10.0.0.200
- DNS servers: (optional, e.g., 1.1.1.1, 8.8.8.8)
- Gateway: 10.0.0.1

### 8. Test Connectivity

#### From OPNsense Console

```
8) Shell

# Test WAN (internet)
ping -c 3 8.8.8.8

# Should succeed if WAN is connected
```

#### From Device on LAN

Connect device to TP-Link switch:

```bash
# Should get IP via DHCP
ip addr
# Expected: 10.0.0.XXX

# Test gateway
ping 10.0.0.1

# Test internet
ping 8.8.8.8
```

---

## Network Topology Verification

```
Internet
   │
Main Router (192.168.1.1)
   │
   ├─ Proxmox Management (192.168.1.110)
   │
   └─ OPNsense WAN (192.168.1.XXX)
         │
    [VM 101: OPNsense]
         │
   OPNsense LAN (10.0.0.1)
         │
   TP-Link Switch
         │
   ├─ DHCP Clients (10.0.0.100-200)
   └─ Future: Talos Nodes
```

---

## Troubleshooting

### OPNsense cannot reach internet

**Check:**
1. WAN interface has IP: `ifconfig vtnet0`
2. Gateway reachable: `ping 192.168.1.1`
3. DNS working: `ping google.com`
4. NAT enabled: Firewall → NAT → Outbound

### Devices on LAN not getting IP

**Check:**
1. DHCP enabled: Services → DHCPv4 → LAN
2. Switch cable connected to correct Proxmox port
3. vmbr1 is UP: `ssh root@192.168.1.110 "ip link show vmbr1"`

### Cannot access OPNsense GUI

**Check:**
1. Laptop on same network as WAN (192.168.1.x)
2. WAN interface configured correctly
3. Firewall not blocking: Firewall → Rules → WAN
4. Try from console: `pfctl -s rules | grep 443`

### Proxmox lost network after bridge changes

**Recovery:**
```bash
# Console access required
nano /etc/network/interfaces
# Remove vmbr1 config temporarily
ifreload -a
```

---

## Next Steps

After manual configuration is complete:

1. **Update Terraform state** (if using):
   ```bash
   cd terraform
   terraform import proxmox_virtual_environment_vm.opnsense 101
   ```

2. **Test Ansible connectivity**:
   ```bash
   ansible -i ansible/inventory/hosts.ini opnsense -m ping
   ```

3. **Proceed with Talos setup**: See `docs/implementation_plan.md`

---

## Quick Reference

### Common OPNsense CLI Commands

```bash
# Restart network
/usr/local/etc/rc.reload_interfaces

# Restart firewall
/etc/rc.filter_configure

# View DHCP leases
dhcpd-leases

# Check WAN status
ifconfig vtnet0

# Check routing
netstat -rn
```

### Common Proxmox VM Commands

```bash
# List VMs
qm list

# VM status
qm status 101

# Stop VM
qm stop 101

# Start VM
qm start 101

# VM config
qm config 101

# Add network device
qm set 101 -net1 virtio,bridge=vmbr1
```
