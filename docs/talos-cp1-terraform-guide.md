# Talos Control Plane 1 - Terraform Setup Guide

This guide documents the Terraform configuration for deploying the first Talos control plane node (talos-cp-1) as a VM on Proxmox.

## Overview

The first control plane node runs as a VM on Proxmox, while subsequent control plane nodes (cp-2, cp-3) will be physical machines. This hybrid approach provides flexibility during initial setup while maintaining production resilience.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ talos-cp-1   │  │ talos-cp-2   │  │ talos-cp-3   │       │
│  │ (VM)         │  │ (Physical)   │  │ (Physical)   │       │
│  │ 10.0.0.10    │  │ 10.0.0.11    │  │ 10.0.0.12    │       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
│         │                 │                 │                │
│         └────────────┬────┴────────┬────────┘                │
│                      │             │                         │
│              ┌───────▼─────────────▼───────┐                 │
│              │     VIP: 10.0.0.5           │                 │
│              │   (Kubernetes API)          │                 │
│              └─────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

Before running this Terraform configuration:

- [ ] OPNsense is running and serving DHCP on the LAN (10.0.0.0/24)
- [ ] `vmbr1` bridge exists on Proxmox (connected to LAN/switch)
- [ ] Terraform is initialized with S3 backend configured
- [ ] Required credentials are set in `terraform.tfvars`

## Files Modified/Created

| File | Purpose |
|------|---------|
| `terraform/variables.tf` | Talos cluster variables |
| `terraform/iso.tf` | Talos ISO download resource |
| `terraform/cluster_talos.tf` | Main Talos resources (secrets, config, VM) |
| `terraform/outputs.tf` | Cluster outputs (talosconfig, MAC address) |
| `terraform/terraform.tfvars.example` | Example variable values |

## Terraform Resources

### 1. Machine Secrets (`talos_machine_secrets.this`)

Generates cryptographic secrets for the cluster:
- CA certificates for Kubernetes and etcd
- Service account keys
- Bootstrap tokens

These secrets are stored in Terraform state and reused for all nodes.

### 2. Client Configuration (`talos_client_configuration.this`)

Generates the `talosconfig` file content for `talosctl` CLI access.

### 3. Machine Configuration (`talos_machine_configuration.cp1`)

Generates the control plane configuration with:
- **VIP**: 10.0.0.5 on eth0 for API high availability
- **Install disk**: /dev/sda
- **Hostname**: talos-cp-1
- **DHCP**: Enabled on eth0
- **Metrics**: Enabled for controller-manager, scheduler, and etcd
- **Scheduling**: Allowed on control planes (single-node friendly)

### 4. Proxmox VM (`proxmox_virtual_environment_vm.talos_cp1`)

Creates the VM with:
- **VM ID**: 200
- **CPU**: 2 cores (x86-64-v2-AES)
- **Memory**: 4096 MB
- **Disk**: 32 GB on local-lvm
- **Network**: Single NIC on vmbr1 (LAN)
- **Boot**: Talos ISO (ide2), then disk (scsi0)

### 5. Configuration Apply (`talos_machine_configuration_apply.cp1`)

Applies the Talos configuration to the booted VM via the Talos API.

## Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `talos_version` | v1.9.0 | Talos Linux version |
| `kubernetes_version` | 1.31.0 | Kubernetes version |
| `talos_cluster_name` | homelab-cluster | Cluster name |
| `talos_cluster_vip` | 10.0.0.5 | API VIP address |
| `talos_cp1_vm_id` | 200 | Proxmox VM ID |
| `talos_cp1_name` | talos-cp-1 | VM hostname |
| `talos_cp1_ip` | 10.0.0.10 | IP (via DHCP reservation) |
| `talos_cp_memory` | 4096 | Memory in MB |
| `talos_cp_cores` | 2 | CPU cores |
| `talos_cp_disk_size` | 32 | Disk size in GB |

## Deployment Workflow

### Step 1: Download ISO and Generate Secrets

```bash
cd terraform

# Download Talos ISO to Proxmox
terraform apply -target=proxmox_virtual_environment_download_file.talos_iso

# Generate cluster secrets (stored in state)
terraform apply -target=talos_machine_secrets.this
```

### Step 2: Create the VM

```bash
# Create VM - it will boot into Talos maintenance mode
terraform apply -target=proxmox_virtual_environment_vm.talos_cp1
```

### Step 3: Get MAC Address for DHCP Reservation

```bash
# Option A: Terraform output
terraform output talos_cp1_mac_address

# Option B: Direct from Proxmox
ssh root@proxmox "qm config 200 | grep net0"
# Output: net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr1
```

### Step 4: Configure DHCP Reservation in OPNsense

1. Navigate to **Services > DHCPv4 > LAN**
2. Scroll to **DHCP Static Mappings**
3. Click **Add** and configure:
   - **MAC Address**: `<from Step 3>`
   - **IP Address**: `10.0.0.10`
   - **Hostname**: `talos-cp-1`
   - **Description**: `Talos Control Plane 1 (VM)`
4. Click **Save** and **Apply Changes**

### Step 5: Reboot VM to Acquire Reserved IP

```bash
ssh root@proxmox "qm reboot 200"

# Wait for VM to boot and verify IP assignment
# Check OPNsense DHCP leases or Proxmox console
```

### Step 6: Apply Talos Configuration

```bash
# This connects to 10.0.0.10 and pushes the configuration
terraform apply -target=talos_machine_configuration_apply.cp1
```

## Post-Terraform Steps

### Export talosconfig

```bash
# Create talos config directory
mkdir -p ~/.talos

# Export configuration
terraform output -raw talosconfig > ~/.talos/config

# Verify
talosctl config info
```

### Verify Node Health

```bash
# Check node is responding
talosctl --nodes 10.0.0.10 health --wait-timeout 5m

# View services
talosctl --nodes 10.0.0.10 services
```

### Bootstrap the Cluster

> **WARNING**: Bootstrap runs only ONCE on the first control plane node. Never run this command again after the initial bootstrap.

```bash
talosctl bootstrap --nodes 10.0.0.10 --endpoints 10.0.0.10
```

### Get Kubeconfig

```bash
# Export kubeconfig
talosctl kubeconfig --nodes 10.0.0.10 -f ~/.kube/config

# Verify cluster access
kubectl get nodes
kubectl get pods -A
```

### Optional: Eject ISO After Install

Once Talos is installed to disk, the ISO can be ejected:

```bash
ssh root@proxmox "qm set 200 --ide2 none,media=cdrom"
```

## Verification Checklist

- [ ] VM 200 created and running in Proxmox
- [ ] VM has MAC address assigned
- [ ] DHCP reservation configured in OPNsense
- [ ] VM acquired IP 10.0.0.10
- [ ] `talosctl health` shows healthy status
- [ ] Cluster bootstrapped successfully
- [ ] `kubectl get nodes` shows talos-cp-1 as Ready

## Troubleshooting

### VM Not Getting Expected IP

1. Verify DHCP reservation MAC matches VM's MAC
2. Check OPNsense DHCP service is running
3. Reboot VM to request new lease

### Talos Configuration Apply Fails

1. Ensure VM is accessible: `ping 10.0.0.10`
2. Check VM is in maintenance mode (not already configured)
3. Verify network path from Terraform host to 10.0.0.10

### Bootstrap Fails

1. Check etcd is running: `talosctl --nodes 10.0.0.10 services`
2. Review logs: `talosctl --nodes 10.0.0.10 logs controller-runtime`
3. Ensure VIP is not conflicting with existing IPs

## Security Notes

- **Secrets in State**: Cluster secrets are stored in Terraform state. Ensure S3 backend has encryption enabled.
- **talosconfig**: Contains admin credentials. Treat as sensitive.
- **VIP Security**: The VIP (10.0.0.5) provides API access. Firewall rules should restrict access as needed.

## Next Steps

After the first control plane is running:

1. Add physical control plane nodes (cp-2, cp-3) using the same secrets
2. Add worker nodes
3. Deploy CNI (Cilium/Flannel)
4. Install ArgoCD for GitOps

See `docs/talos-setup-guide.md` for manual node addition procedures.
