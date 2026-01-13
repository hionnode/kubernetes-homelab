# Homelab Automation Scripts

Bash-only automation alternative to Terraform/Ansible approach.

## Overview

These scripts automate the homelab setup in sequential order:

1. **`01-setup-proxmox.sh`** - Proxmox network bridges and OPNsense VM
2. **`02-setup-opnsense.sh`** - OPNsense configuration via API
3. **`03-setup-talos.sh`** - Talos Kubernetes control plane (template)

## Prerequisites

- Fresh Proxmox VE installation (tested on 8.x)
- Two physical network interfaces on Proxmox host
- SSH access to Proxmox from your workstation
- `curl`, `wget`, `bunzip2` available on Proxmox

## Usage

### From Your Workstation (Recommended)

```bash
# Export Proxmox connection
export PROXMOX_HOST=192.168.1.110

# Run scripts in order
./scripts/01-setup-proxmox.sh
# ... follow manual steps for OPNsense install ...
./scripts/02-setup-opnsense.sh
```

### Directly on Proxmox

```bash
# Copy scripts to Proxmox
scp scripts/*.sh root@192.168.1.110:/root/

# SSH and run
ssh root@192.168.1.110
chmod +x /root/*.sh
./01-setup-proxmox.sh
```

## Script Details

### 01-setup-proxmox.sh

**What it does:**
- Creates `vmbr1` bridge for LAN network
- Downloads OPNsense ISO (decompresses bz2)
- Creates OPNsense VM with dual NICs
- Starts VM for installation

**Variables:**
- `PROXMOX_HOST` - Proxmox IP (default: 192.168.1.110)
- `WAN_INTERFACE` - Physical WAN port (default: enp2s0)
- `LAN_INTERFACE` - Physical LAN port (default: enx1c860b363f63)
- `OPNSENSE_VMID` - VM ID (default: 100)

**Manual steps after:**
1. Access VM console (Proxmox GUI → VM 100 → Console)
2. Login: `installer` / `opnsense`
3. Run: `opnsense-installer`
4. Assign interfaces (vtnet0=WAN, vtnet1=LAN)
5. Generate API keys

### 02-setup-opnsense.sh

**What it does:**
- Configures OPNsense via API
- Note: Limited due to OPNsense API complexity

**Variables:**
- `OPNSENSE_HOST` - OPNsense WAN IP
- `OPNSENSE_API_KEY` - API key from GUI
- `OPNSENSE_API_SECRET` - API secret from GUI

**Status:** Partial implementation
- Full firewall/NAT automation requires version-specific API exploration
- Use Ansible `ansibleguy.opnsense` collection for comprehensive automation

### 03-setup-talos.sh

**Status:** Template only
- Placeholder for future Talos implementation
- See Terraform approach in main docs for now

## Comparison with Terraform/Ansible

| Feature | Bash Scripts | Terraform/Ansible |
|---------|-------------|-------------------|
| Speed | ⚡ Fast (seconds) | 🐌 Slow (minutes) |
| State Tracking | ❌ Manual | ✅ Automatic |
| Idempotency | ⚠️ Partial | ✅ Full |
| Complexity | ✅ Simple | ⚠️ Complex |
| **Best for** | Quick rebuilds, dev | Production, teams |

## Troubleshooting

**"vmbr1 already exists"**
- Script detects and skips. Safe to re-run.

**"VM 100 already exists"**
- Delete first: `ssh root@192.168.1.110 "qm stop 100 && qm destroy 100"`

**"Connection refused" on OPNsense API**
- Ensure OPNsense is running
- Check firewall rules allow access from your IP
- Verify API key/secret are correct

## Security Notes

- Scripts use SSH without key validation (`-o StrictHostKeyChecking=no` not added - use ssh-copy-id first)
- OPNsense API credentials in environment variables (safer than files)
- Never commit credentials to git

## See Also

- `docs/hybrid_workflow.md` - When to use Bash vs Terraform
- `docs/walkthrough.md` - Complete manual setup guide
