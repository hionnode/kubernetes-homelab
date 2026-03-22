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

## Diagnostic Scripts

Independent troubleshooting tools for incident response. Each maps to a section in [`docs/opnsense-guide.md`](../docs/opnsense-guide.md).

| Script | Purpose | Guide Section | Requires |
|--------|---------|---------------|----------|
| `diag-health-check.sh` | Five-layer connectivity triage | 3.1 | Workstation only |
| `diag-dns-matrix.sh` | DNS diagnostic test matrix (6 tests) | 8.5 | Workstation + `dig` |
| `diag-static-ip.sh` | Emergency static IP assign/revert | 4.2 | Workstation + sudo |
| `diag-collect.sh` | Collect diagnostics from all hosts | 3.3 | SSH to Proxmox/OPNsense |
| `diag-pre-update.sh` | Snapshot + state capture before updates | 13.4 | SSH to Proxmox/OPNsense |
| `collect-opnsense-logs.sh` | Pull Kea/Unbound logs, configs, leases via SSH | 7.6, 8.6 | SSH to OPNsense |

### Quick Usage

```bash
# Start here — quick triage of all network layers
./scripts/diag-health-check.sh

# DNS not working? Run the full test matrix
./scripts/diag-dns-matrix.sh

# DHCP down? Assign a static IP to reach OPNsense
./scripts/diag-static-ip.sh
./scripts/diag-static-ip.sh --cleanup    # restore DHCP after

# Collect full diagnostic data for analysis
./scripts/diag-collect.sh

# Before an OPNsense firmware update
./scripts/diag-pre-update.sh --backup-config

# Pull all OPNsense logs for offline analysis
./scripts/collect-opnsense-logs.sh                    # LAN (10.0.0.1)
./scripts/collect-opnsense-logs.sh 192.168.1.50       # WAN IP if LAN is down
```

All scripts support `--help` for full usage details. Configuration is via environment variables (e.g., `PROXMOX_HOST`, `OPNSENSE_LAN`).

## See Also

- `docs/hybrid_workflow.md` - When to use Bash vs Terraform
- `docs/walkthrough.md` - Complete manual setup guide
- `docs/opnsense-guide.md` - Full troubleshooting reference
