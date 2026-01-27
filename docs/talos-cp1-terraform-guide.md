# Building a Production-Grade Kubernetes Homelab: Talos Linux on Proxmox with Terraform

A comprehensive guide to deploying the first Talos Linux control plane node as a VM on Proxmox, fully automated with Terraform and the Siderolabs Talos provider.

---

## Table of Contents

1. [Introduction](#introduction)
2. [Why Talos Linux?](#why-talos-linux)
3. [Architecture Overview](#architecture-overview)
4. [Prerequisites](#prerequisites)
5. [Infrastructure Foundation](#infrastructure-foundation)
6. [Terraform Implementation](#terraform-implementation)
7. [Step-by-Step Deployment](#step-by-step-deployment)
8. [Post-Deployment Configuration](#post-deployment-configuration)
9. [Verification and Testing](#verification-and-testing)
10. [Troubleshooting](#troubleshooting)
11. [Security Considerations](#security-considerations)
12. [Next Steps](#next-steps)

---

## Introduction

This guide documents the process of setting up the first control plane node for a Kubernetes homelab using Talos Linux. Rather than manually configuring everything, we'll use Infrastructure as Code (IaC) with Terraform to ensure reproducibility and maintainability.

### What We're Building

By the end of this guide, you'll have:

- A Talos Linux control plane VM running on Proxmox
- Cluster secrets managed by Terraform
- A single-node Kubernetes cluster ready for expansion
- Full automation that can be version-controlled and reproduced

### The Hybrid Approach

Our cluster uses a hybrid VM + physical node topology:

- **Control Plane 1 (VM)**: Runs on Proxmox for easy management and snapshots
- **Control Planes 2-3 (Physical)**: Mini PCs for true hardware redundancy
- **Workers 1-3 (Physical)**: Dedicated compute nodes

This approach gives us the best of both worlds: easy iteration during setup (VMs) and production resilience (physical nodes).

---

## Why Talos Linux?

Talos Linux is a modern OS designed specifically for Kubernetes. Here's why it's ideal for a homelab:

### Immutable and Secure

- **No SSH access**: The entire OS is managed via an API
- **Read-only root filesystem**: No drift, no unauthorized changes
- **Minimal attack surface**: Only includes what Kubernetes needs

### Declarative Configuration

- **YAML-based**: All configuration is declarative
- **API-driven**: Every change goes through the Talos API
- **GitOps-friendly**: Perfect for Infrastructure as Code

### Kubernetes-Native

- **Built for K8s**: Not a general-purpose OS with K8s bolted on
- **Fast upgrades**: In-place OS and Kubernetes upgrades
- **Consistent**: Same experience on VM, bare metal, or cloud

### Homelab Benefits

- **Low resource usage**: ~300MB RAM for the OS itself
- **Quick setup**: Boot to running cluster in minutes
- **Easy recovery**: Regenerate nodes from config files

---

## Architecture Overview

### Network Topology

```
                              INTERNET
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │     Main Router         │
                    │     192.168.1.1         │
                    └───────────┬─────────────┘
                                │
            ┌───────────────────┴───────────────────┐
            │                                       │
            ▼                                       ▼
    ┌───────────────┐                     ┌─────────────────┐
    │   Proxmox     │                     │   OPNsense VM   │
    │ 192.168.1.110 │                     │   WAN: DHCP     │
    │   (vmbr0)     │                     │   LAN: 10.0.0.1 │
    └───────────────┘                     └────────┬────────┘
                                                   │
                                    ┌──────────────┴──────────────┐
                                    │         LAN (vmbr1)         │
                                    │        10.0.0.0/24          │
                                    └──────────────┬──────────────┘
                                                   │
                    ┌──────────────────────────────┼──────────────────────────────┐
                    │                              │                              │
                    ▼                              ▼                              ▼
          ┌─────────────────┐            ┌─────────────────┐            ┌─────────────────┐
          │   talos-cp-1    │            │   talos-cp-2    │            │   talos-cp-3    │
          │   (VM) 200      │            │   (Physical)    │            │   (Physical)    │
          │   10.0.0.10     │            │   10.0.0.11     │            │   10.0.0.12     │
          └────────┬────────┘            └────────┬────────┘            └────────┬────────┘
                   │                              │                              │
                   └──────────────────────────────┼──────────────────────────────┘
                                                  │
                                    ┌─────────────▼─────────────┐
                                    │    Kubernetes API VIP     │
                                    │        10.0.0.5           │
                                    └───────────────────────────┘
```

### IP Allocation Plan

| Resource | IP Address | Description |
|----------|------------|-------------|
| OPNsense LAN | 10.0.0.1 | Gateway, DHCP, DNS |
| Kubernetes VIP | 10.0.0.5 | API server high availability |
| talos-cp-1 | 10.0.0.10 | Control plane (VM on Proxmox) |
| talos-cp-2 | 10.0.0.11 | Control plane (Physical) |
| talos-cp-3 | 10.0.0.12 | Control plane (Physical) |
| talos-worker-1 | 10.0.0.20 | Worker node (Physical) |
| talos-worker-2 | 10.0.0.21 | Worker node (Physical) |
| talos-worker-3 | 10.0.0.22 | Worker node (Physical) |
| MetalLB Pool | 10.0.0.50-99 | LoadBalancer service IPs |
| DHCP Pool | 10.0.0.100-200 | Dynamic allocation |

### Why a Virtual IP (VIP)?

The VIP (10.0.0.5) is a floating IP that moves between control plane nodes. This provides:

- **High availability**: If one control plane goes down, another takes over the VIP
- **Stable endpoint**: Your kubeconfig always points to 10.0.0.5, not a specific node
- **Seamless failover**: Clients don't need reconfiguration during node failures

Talos implements this using a built-in VIP manager that uses ARP announcements.

---

## Prerequisites

### Infrastructure Requirements

Before starting, ensure you have:

- [x] **Proxmox VE** installed and accessible (we're using 192.168.1.110)
- [x] **OPNsense VM** running with:
  - LAN interface on 10.0.0.1/24
  - DHCP server enabled on LAN
  - Connected to vmbr1 bridge
- [x] **Network bridges** configured on Proxmox:
  - `vmbr0`: WAN network (192.168.1.0/24)
  - `vmbr1`: LAN network (10.0.0.0/24)

### Software Requirements

On your workstation:

```bash
# Terraform (>= 1.10.0)
brew install terraform  # macOS
# or
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform

# Talosctl CLI
curl -sL https://talos.dev/install | sh

# Verify installations
terraform --version  # Should show >= 1.10.0
talosctl version --client  # Should show latest version
```

### Credentials Required

You'll need these credentials configured in `terraform/terraform.tfvars`:

```hcl
# Proxmox credentials
proxmox_endpoint = "https://192.168.1.110:8006/"
proxmox_username = "terraform@pve"
proxmox_password = "your-proxmox-password"
proxmox_node     = "pve"

# OPNsense API credentials
opnsense_uri        = "https://10.0.0.1"
opnsense_api_key    = "your-api-key"
opnsense_api_secret = "your-api-secret"
```

### Terraform Backend

Our configuration uses an S3 backend for state storage. Ensure you have:

- AWS credentials configured (`~/.aws/credentials` or environment variables)
- An S3 bucket for Terraform state
- DynamoDB table for state locking (optional but recommended)

---

## Infrastructure Foundation

### What We Built Previously

This guide builds on existing infrastructure:

1. **Proxmox Host**: Mini PC running Proxmox VE with two network bridges
2. **OPNsense VM**: Firewall/router providing network services for the Kubernetes network
3. **Terraform Configuration**: Base setup for Proxmox and OPNsense providers

### Repository Structure

```
kubernetes-homelab/
├── terraform/
│   ├── providers.tf          # Provider configurations
│   ├── versions.tf           # Terraform and provider versions
│   ├── variables.tf          # Input variables
│   ├── outputs.tf            # Output values
│   ├── iso.tf                # ISO download resources
│   ├── vm_opnsense.tf        # OPNsense VM definition
│   ├── config_opnsense.tf    # OPNsense firewall/DHCP config
│   ├── cluster_talos.tf      # Talos cluster resources (this guide)
│   └── terraform.tfvars      # Variable values (gitignored)
├── docs/
│   └── talos-cp1-terraform-guide.md  # This document
└── CLAUDE.md                 # Project documentation
```

---

## Terraform Implementation

Let's walk through each file we created or modified for the Talos setup.

### 1. Variables (`terraform/variables.tf`)

We added variables for Talos configuration:

```hcl
# Talos Cluster Variables
variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.9.0"
}

variable "kubernetes_version" {
  description = "Kubernetes version for Talos cluster"
  type        = string
  default     = "1.31.0"
}

variable "talos_cluster_name" {
  description = "Name of the Talos Kubernetes cluster"
  type        = string
  default     = "homelab-cluster"
}

variable "talos_cluster_vip" {
  description = "Virtual IP for Kubernetes API high availability"
  type        = string
  default     = "10.0.0.5"
}

variable "talos_cp1_vm_id" {
  description = "Proxmox VM ID for talos-cp-1"
  type        = number
  default     = 200
}

variable "talos_cp1_name" {
  description = "VM name for the first Talos control plane"
  type        = string
  default     = "talos-cp-1"
}

variable "talos_cp1_ip" {
  description = "IP address for talos-cp-1 (via DHCP reservation)"
  type        = string
  default     = "10.0.0.10"
}

variable "talos_cp_memory" {
  description = "Memory (MB) for Talos control plane VMs"
  type        = number
  default     = 4096
}

variable "talos_cp_cores" {
  description = "CPU cores for Talos control plane VMs"
  type        = number
  default     = 2
}

variable "talos_cp_disk_size" {
  description = "Disk size (GB) for Talos control plane VMs"
  type        = number
  default     = 32
}
```

**Design decisions:**

- **4GB RAM**: Sufficient for control plane components + small workloads
- **2 cores**: Adequate for etcd and API server
- **32GB disk**: Room for etcd data, container images, and logs

### 2. ISO Download (`terraform/iso.tf`)

Added Talos ISO download resource:

```hcl
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node
  url          = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-amd64.iso"
}
```

This downloads the Talos ISO directly to Proxmox's ISO storage, eliminating manual upload steps.

### 3. Talos Resources (`terraform/cluster_talos.tf`)

This is the core of our implementation. Let's break it down:

#### Machine Secrets

```hcl
resource "talos_machine_secrets" "this" {}
```

Generates cryptographic material for the cluster:
- Kubernetes CA certificate and key
- etcd CA certificate and key
- Service account signing key
- Bootstrap token

**These secrets are stored in Terraform state and reused for ALL nodes in the cluster.**

#### Client Configuration

```hcl
data "talos_client_configuration" "this" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.talos_cp1_ip]
  nodes                = [var.talos_cp1_ip]
}
```

Generates the `talosconfig` file that `talosctl` uses to communicate with the cluster.

#### Machine Configuration

```hcl
data "talos_machine_configuration" "cp1" {
  cluster_name     = var.talos_cluster_name
  cluster_endpoint = "https://${var.talos_cluster_vip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda"
        }
        network = {
          hostname = var.talos_cp1_name
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              vip = {
                ip = var.talos_cluster_vip
              }
            }
          ]
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
        controllerManager = {
          extraArgs = {
            bind-address = "0.0.0.0"
          }
        }
        scheduler = {
          extraArgs = {
            bind-address = "0.0.0.0"
          }
        }
        proxy = {
          disabled = false
        }
        etcd = {
          extraArgs = {
            listen-metrics-urls = "http://0.0.0.0:2381"
          }
        }
      }
    })
  ]
}
```

**Configuration highlights:**

- **cluster_endpoint**: Points to VIP (10.0.0.5), not individual node
- **install.disk**: Installs Talos to /dev/sda (the VM's disk)
- **dhcp: true**: Gets IP from OPNsense DHCP
- **vip.ip**: Configures the floating VIP for API HA
- **allowSchedulingOnControlPlanes**: Enables workloads on control plane (useful for single-node testing)
- **bind-address: 0.0.0.0**: Exposes metrics for monitoring (Prometheus/Grafana)
- **listen-metrics-urls**: Enables etcd metrics endpoint

#### Proxmox VM

```hcl
resource "proxmox_virtual_environment_vm" "talos_cp1" {
  name      = var.talos_cp1_name
  node_name = var.proxmox_node
  vm_id     = var.talos_cp1_vm_id

  machine = "q35"
  bios    = "seabios"

  cpu {
    cores = var.talos_cp_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.talos_cp_memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.talos_cp_disk_size
    file_format  = "raw"
  }

  cdrom {
    enabled   = true
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = false
  }

  on_boot = true
  started = true

  boot_order = ["ide2", "scsi0"]

  lifecycle {
    ignore_changes = [
      cdrom,
      boot_order
    ]
  }
}
```

**VM configuration details:**

- **machine = "q35"**: Modern chipset with better performance
- **cpu type = "x86-64-v2-AES"**: Good compatibility with AES acceleration
- **vmbr1**: LAN network where Kubernetes runs
- **virtio**: Best performance for Linux guests
- **l26**: Linux 2.6+ kernel type
- **agent disabled**: Talos doesn't support QEMU guest agent
- **lifecycle ignore_changes**: Prevents Terraform from fighting with manual ISO ejection

#### Configuration Apply

```hcl
resource "talos_machine_configuration_apply" "cp1" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp1.machine_configuration
  node                        = var.talos_cp1_ip
  endpoint                    = var.talos_cp1_ip

  depends_on = [proxmox_virtual_environment_vm.talos_cp1]
}
```

This resource applies the generated configuration to the booted Talos node. It:

1. Connects to the node at 10.0.0.10
2. Pushes the machine configuration
3. Triggers Talos to install to disk and configure itself

### 4. Outputs (`terraform/outputs.tf`)

```hcl
output "talosconfig" {
  description = "Talos client configuration for talosctl"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "talos_cp1_vm_id" {
  description = "VM ID of talos-cp-1"
  value       = proxmox_virtual_environment_vm.talos_cp1.vm_id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = "https://${var.talos_cluster_vip}:6443"
}

output "talos_cp1_mac_address" {
  description = "MAC address of talos-cp-1 (for DHCP reservation)"
  value       = proxmox_virtual_environment_vm.talos_cp1.network_device[0].mac_address
}
```

**Key outputs:**

- **talosconfig**: Required for `talosctl` to manage the cluster
- **talos_cp1_mac_address**: Needed for DHCP reservation in OPNsense

---

## Step-by-Step Deployment

### Step 1: Initialize Terraform

```bash
cd terraform

# Initialize providers and backend
terraform init

# Verify configuration
terraform validate
```

### Step 2: Download Talos ISO

```bash
# Download ISO to Proxmox storage
terraform apply -target=proxmox_virtual_environment_download_file.talos_iso

# Verify in Proxmox UI: Datacenter > pve > local > ISO Images
# Should see: talos-v1.9.0-amd64.iso
```

### Step 3: Generate Cluster Secrets

```bash
# Generate cryptographic secrets
terraform apply -target=talos_machine_secrets.this

# These are now stored in Terraform state
# IMPORTANT: Ensure your S3 backend has encryption enabled
```

### Step 4: Create the VM

```bash
# Create the Talos control plane VM
terraform apply -target=proxmox_virtual_environment_vm.talos_cp1
```

The VM will:
1. Boot from the Talos ISO
2. Enter "maintenance mode" (waiting for configuration)
3. Get a DHCP IP (might not be 10.0.0.10 yet)

**Check the Proxmox console** to see Talos boot. You'll see:

```
Talos (v1.9.0)
...
waiting for configuration...
```

### Step 5: Get MAC Address for DHCP Reservation

```bash
# Option A: From Terraform output
terraform output talos_cp1_mac_address

# Option B: From Proxmox directly
ssh root@proxmox "qm config 200 | grep net0"
# Output: net0: virtio=BC:24:11:XX:XX:XX,bridge=vmbr1
```

### Step 6: Configure DHCP Reservation in OPNsense

This ensures the VM always gets 10.0.0.10:

1. Open OPNsense web UI: `https://10.0.0.1`
2. Navigate to **Services > DHCPv4 > LAN**
3. Scroll down to **DHCP Static Mappings for this Interface**
4. Click **+ Add**
5. Configure:
   - **MAC Address**: `BC:24:11:XX:XX:XX` (from Step 5)
   - **IP Address**: `10.0.0.10`
   - **Hostname**: `talos-cp-1`
   - **Description**: `Talos Control Plane 1 (VM)`
6. Click **Save**
7. Click **Apply Changes**

### Step 7: Reboot VM to Acquire Reserved IP

```bash
# Reboot the VM to get the new IP
ssh root@proxmox "qm reboot 200"

# Wait 30-60 seconds for boot

# Verify IP assignment in OPNsense:
# Services > DHCPv4 > Leases
# Should show: talos-cp-1 at 10.0.0.10
```

### Step 8: Apply Talos Configuration

```bash
# Push configuration to the node
terraform apply -target=talos_machine_configuration_apply.cp1
```

This will:
1. Connect to 10.0.0.10 via Talos API
2. Push the machine configuration
3. Trigger installation to /dev/sda
4. Reboot into the installed system

**Watch progress** in Proxmox console. You'll see:
- Installation progress
- Reboot
- Kubernetes components starting

---

## Post-Deployment Configuration

### Export talosconfig

```bash
# Create talos config directory
mkdir -p ~/.talos

# Export the configuration
terraform output -raw talosconfig > ~/.talos/config

# Set environment variable (add to ~/.bashrc or ~/.zshrc)
export TALOSCONFIG=~/.talos/config

# Verify configuration
talosctl config info
```

### Bootstrap the Cluster

> **CRITICAL**: Bootstrap runs ONLY ONCE on the FIRST control plane node. Running it again can corrupt etcd.

```bash
# Bootstrap etcd and start Kubernetes
talosctl bootstrap --nodes 10.0.0.10 --endpoints 10.0.0.10
```

This initializes:
- etcd cluster (single member initially)
- Kubernetes control plane components
- Core system pods

**Wait for bootstrap to complete** (2-5 minutes).

### Get Kubeconfig

```bash
# Export kubeconfig
talosctl kubeconfig --nodes 10.0.0.10 -f ~/.kube/config

# Verify cluster access
kubectl cluster-info
kubectl get nodes
```

### Optional: Eject ISO

After installation, the ISO is no longer needed:

```bash
ssh root@proxmox "qm set 200 --ide2 none,media=cdrom"
```

---

## Verification and Testing

### Verification Checklist

Run through these checks to ensure everything is working:

```bash
# 1. Check Talos node health
talosctl health --nodes 10.0.0.10

# Expected output:
# discovered nodes: ["10.0.0.10"]
# service "etcd" is healthy
# service "kubelet" is healthy
# ...
# all checks passed!

# 2. Check Talos services
talosctl services --nodes 10.0.0.10

# All services should show "Running"

# 3. Check Kubernetes node
kubectl get nodes -o wide

# Expected:
# NAME         STATUS   ROLES           AGE   VERSION   INTERNAL-IP
# talos-cp-1   Ready    control-plane   5m    v1.31.0   10.0.0.10

# 4. Check system pods
kubectl get pods -A

# All pods should be Running or Completed

# 5. Verify VIP is active
ping 10.0.0.5

# Should respond (VIP is on this node since it's the only control plane)

# 6. Test API via VIP
kubectl --server=https://10.0.0.5:6443 get nodes

# Should work - confirms VIP is properly configured
```

### Interactive Dashboard

Talos provides a real-time dashboard:

```bash
talosctl dashboard --nodes 10.0.0.10
```

This shows:
- CPU/Memory usage
- Running services
- Logs in real-time
- Network information

---

## Troubleshooting

### VM Not Getting Expected IP

**Symptoms**: VM gets 10.0.0.1xx instead of 10.0.0.10

**Solutions**:
1. Verify DHCP reservation MAC matches exactly
2. Check OPNsense DHCP service is running
3. Release old lease: In OPNsense, delete the old lease entry
4. Reboot VM: `ssh root@proxmox "qm reboot 200"`

### Talos Configuration Apply Fails

**Symptoms**: Terraform hangs or times out on `talos_machine_configuration_apply`

**Solutions**:

```bash
# 1. Check connectivity
ping 10.0.0.10

# 2. Check if Talos API is responding
talosctl --nodes 10.0.0.10 version --insecure

# 3. If node is already configured, you may need to reset it:
talosctl reset --nodes 10.0.0.10 --graceful=false --reboot

# 4. Check Proxmox console for errors
```

### Bootstrap Fails

**Symptoms**: `talosctl bootstrap` returns an error

**Solutions**:

```bash
# 1. Check if bootstrap already ran
talosctl etcd members --nodes 10.0.0.10
# If this shows members, bootstrap already completed

# 2. Check etcd logs
talosctl logs etcd --nodes 10.0.0.10

# 3. Check controller-runtime logs
talosctl logs controller-runtime --nodes 10.0.0.10

# 4. Ensure VIP isn't conflicting
# Check no other device has 10.0.0.5
```

### Node Shows NotReady

**Symptoms**: `kubectl get nodes` shows NotReady

**Solutions**:

```bash
# 1. Check kubelet status
talosctl service kubelet --nodes 10.0.0.10

# 2. Check kubelet logs
talosctl logs kubelet --nodes 10.0.0.10

# 3. CNI might be missing (expected until we install one)
# Single-node cluster should work without CNI for control plane pods
```

### Reset and Start Over

If you need to completely reset:

```bash
# 1. Reset Talos (wipes everything)
talosctl reset --nodes 10.0.0.10 --graceful=false --reboot

# 2. Destroy Terraform resources
terraform destroy -target=talos_machine_configuration_apply.cp1
terraform destroy -target=proxmox_virtual_environment_vm.talos_cp1
terraform destroy -target=talos_machine_secrets.this

# 3. Re-apply from scratch
terraform apply
```

---

## Security Considerations

### Secrets Management

**Terraform State Security**:
- Cluster secrets (CAs, keys) are stored in Terraform state
- **Ensure S3 backend encryption is enabled**
- Consider using state encryption with a KMS key
- Limit access to the state bucket

**talosconfig Security**:
- Contains admin credentials for the cluster
- Treat like a kubeconfig - it provides full cluster access
- Don't commit to version control
- Consider using Vault or similar for production

### Network Security

**API Access**:
- Kubernetes API is exposed on 10.0.0.5:6443
- Currently accessible from entire 10.0.0.0/24 network
- Consider OPNsense firewall rules to restrict access

**Talos API**:
- Exposed on port 50000
- Only accessible with valid talosconfig
- No SSH access (by design)

### Future Improvements

For production environments, consider:
- [ ] TLS certificates from a proper CA (not self-signed)
- [ ] Network policies to restrict pod-to-pod traffic
- [ ] OPNsense firewall rules for API access
- [ ] Audit logging enabled
- [ ] Encrypted etcd (Talos supports this)

---

## Next Steps

With the first control plane running, here's the roadmap for completing the cluster:

### Phase 1: Expand Control Plane (High Availability)

Add two more control plane nodes for etcd quorum and API redundancy:

1. **Boot physical machines from Talos USB**
   ```bash
   # Download and create USB
   curl -LO https://github.com/siderolabs/talos/releases/download/v1.9.0/metal-amd64.raw.xz
   xz -d metal-amd64.raw.xz
   sudo dd if=metal-amd64.raw of=/dev/sdX bs=4M status=progress
   ```

2. **Configure DHCP reservations** for 10.0.0.11 and 10.0.0.12

3. **Apply configuration** (reusing secrets from Terraform state):
   ```bash
   # Generate config for cp-2 and cp-3
   talosctl gen config homelab-cluster https://10.0.0.5:6443 \
       --with-secrets <(terraform output -raw machine_secrets) \
       --output-dir ./configs

   # Apply to each node
   talosctl apply-config --insecure --nodes 10.0.0.11 --file configs/controlplane.yaml
   talosctl apply-config --insecure --nodes 10.0.0.12 --file configs/controlplane.yaml
   ```

4. **Update talosconfig endpoints**:
   ```bash
   talosctl config endpoint 10.0.0.10 10.0.0.11 10.0.0.12
   ```

### Phase 2: Add Worker Nodes

Add dedicated compute nodes for workloads:

1. Boot workers from Talos USB
2. Configure DHCP reservations (10.0.0.20-22)
3. Apply worker configuration:
   ```bash
   talosctl apply-config --insecure --nodes 10.0.0.20 --file configs/worker.yaml
   ```

### Phase 3: Install CNI (Cilium)

Deploy Container Network Interface for pod networking:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true
```

### Phase 4: Install MetalLB (LoadBalancer)

Enable LoadBalancer services with MetalLB:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Configure IP pool (10.0.0.50-99)
kubectl apply -f - <<EOF
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
EOF
```

### Phase 5: Deploy ArgoCD (GitOps)

Set up GitOps for declarative cluster management:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Phase 6: Observability Stack

Deploy monitoring and logging:

- **Prometheus**: Metrics collection
- **Grafana**: Visualization dashboards
- **Loki**: Log aggregation

See `docs/observability-guide.md` for detailed setup.

### Phase 7: Storage (Longhorn or Rook-Ceph)

Add persistent storage for stateful workloads:

```bash
# Longhorn (simpler)
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml

# Or Rook-Ceph (more features)
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/crds.yaml
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/common.yaml
kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/operator.yaml
```

---

## Summary

We've successfully deployed the first Talos Linux control plane node using Terraform. Key accomplishments:

- **Infrastructure as Code**: All configuration is version-controlled and reproducible
- **Automated Provisioning**: ISO download, VM creation, and configuration are automated
- **Production-Ready Foundation**: VIP, metrics, and proper secrets management
- **Clear Path Forward**: Documented next steps for cluster expansion

The combination of Talos Linux + Terraform + Proxmox provides a solid foundation for a production-grade homelab Kubernetes cluster.

---

## References

- [Talos Linux Documentation](https://www.talos.dev/docs/)
- [Terraform Talos Provider](https://registry.terraform.io/providers/siderolabs/talos/latest/docs)
- [BPG Proxmox Provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

---

*Last updated: January 2025*
