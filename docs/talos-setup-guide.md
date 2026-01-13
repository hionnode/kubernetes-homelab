# Talos Linux Manual Setup Guide

Complete setup guide for a hybrid Talos Kubernetes cluster with VM and physical nodes.

---

## Cluster Architecture

```
OPNsense (10.0.0.1)
       │
  TP-Link Switch
       │
  ├── VM: talos-cp-1 (10.0.0.10) - Control Plane [Proxmox]
  ├── Physical: talos-cp-2 (10.0.0.11) - Control Plane
  ├── Physical: talos-cp-3 (10.0.0.12) - Control Plane
  ├── Physical: talos-worker-1 (10.0.0.20) - Worker
  ├── Physical: talos-worker-2 (10.0.0.21) - Worker
  └── Physical: talos-worker-3 (10.0.0.22) - Worker
```

**Virtual IP (VIP):** `10.0.0.5` - Shared by control plane nodes for API server HA

---

## Prerequisites

### On Your Workstation

```bash
# Install talosctl
curl -sL https://talos.dev/install | sh

# Verify
talosctl version --client
```

### On OPNsense (via Web UI)

Configure DHCP reservations for predictable IPs:

**Services → DHCPv4 → LAN → Scroll to DHCP Static Mappings → Click +**

For each node, add:
- **MAC Address**: Get from Proxmox VM config or boot node and check leases
- **IP Address**: As shown below
- **Hostname**: Node name
- **Description**: Role

| Hostname | IP Address | Role |
|----------|------------|------|
| talos-cp-1 | 10.0.0.10 | Control Plane (VM) |
| talos-cp-2 | 10.0.0.11 | Control Plane (Physical) |
| talos-cp-3 | 10.0.0.12 | Control Plane (Physical) |
| talos-worker-1 | 10.0.0.20 | Worker |
| talos-worker-2 | 10.0.0.21 | Worker |
| talos-worker-3 | 10.0.0.22 | Worker |

> 📖 See [opnsense-configuration-guide.md](opnsense-configuration-guide.md) for detailed OPNsense UI steps

---

## Part 1: Download Talos Assets

### Get Latest Talos Version

```bash
# Check latest version
curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | grep tag_name
# Example: v1.9.0

export TALOS_VERSION="v1.9.0"
```

### Download ISO (for VM)

```bash
# Download to local machine
curl -LO https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talos-amd64.iso

# Upload to Proxmox
scp talos-amd64.iso root@192.168.1.110:/var/lib/vz/template/iso/
```

### Download for Physical Nodes (USB Boot)

```bash
# Download raw image for USB
curl -LO https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talos-amd64.raw.xz

# Write to USB (replace /dev/sdX with your USB device)
xz -d talos-amd64.raw.xz
sudo dd if=talos-amd64.raw of=/dev/sdX bs=4M status=progress
sync
```

---

## Part 2: Generate Talos Configuration

### Create Secrets

```bash
mkdir -p ~/homelab-talos && cd ~/homelab-talos

# Generate secrets (DO THIS ONLY ONCE - SAVE THESE!)
talosctl gen secrets -o secrets.yaml

# Keep this file safe - required for cluster recovery
```

### Generate Machine Configs

```bash
# Generate configs with VIP for HA
talosctl gen config homelab-cluster https://10.0.0.5:6443 \
    --with-secrets secrets.yaml \
    --output-dir . \
    --config-patch-control-plane @control-plane-patch.yaml \
    --config-patch-worker @worker-patch.yaml

# This creates:
# - controlplane.yaml
# - worker.yaml
# - talosconfig
```

### Create Control Plane Patch

Create `control-plane-patch.yaml`:

```yaml
machine:
  network:
    interfaces:
      - deviceSelector:
          busPath: "0*"  # First network device
        dhcp: true
        vip:
          ip: 10.0.0.5  # Shared VIP for API server

cluster:
  allowSchedulingOnControlPlanes: false
  
  # Enable metrics
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
  proxy:
    disabled: false
  
  # etcd configuration
  etcd:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
```

### Create Worker Patch

Create `worker-patch.yaml`:

```yaml
machine:
  network:
    interfaces:
      - deviceSelector:
          busPath: "0*"
        dhcp: true
```

---

## Part 3: VM Control Plane Node (Proxmox)

### Create VM

```bash
ssh root@192.168.1.110

# Create Talos control plane VM
qm create 200 \
    --name talos-cp-1 \
    --cores 2 \
    --memory 4096 \
    --net0 virtio,bridge=vmbr1 \
    --scsi0 local-lvm:32 \
    --ide2 local:iso/talos-amd64.iso,media=cdrom \
    --boot order=ide2 \
    --ostype l26 \
    --agent 0

# Start VM
qm start 200
```

### Apply Configuration

Wait for VM to boot (shows Talos maintenance mode):

```bash
# From your workstation
export TALOS_CP1="10.0.0.10"

# Apply control plane config
talosctl apply-config --insecure \
    --nodes $TALOS_CP1 \
    --file controlplane.yaml

# VM will reboot and come up with configuration
```

### Bootstrap First Node

**IMPORTANT:** Only run bootstrap on ONE control plane node (the first one):

```bash
# Set up talosctl config
export TALOSCONFIG="$HOME/homelab-talos/talosconfig"
talosctl config endpoint $TALOS_CP1
talosctl config node $TALOS_CP1

# Bootstrap etcd (only on first control plane!)
talosctl bootstrap --nodes $TALOS_CP1

# Watch progress
talosctl dmesg -f --nodes $TALOS_CP1
```

### Verify First Node

```bash
# Check node health
talosctl health --nodes $TALOS_CP1

# Get kubeconfig
talosctl kubeconfig --nodes $TALOS_CP1 -f ~/.kube/config

# Verify cluster
kubectl get nodes
```

---

## Part 4: Physical Control Plane Nodes

### Boot from USB

1. Insert Talos USB into physical machine
2. Boot from USB (F12/F2 for boot menu)
3. Wait for Talos maintenance mode
4. Note the assigned IP (if DHCP) or check OPNsense leases

### Apply Configuration

```bash
export TALOS_CP2="10.0.0.11"
export TALOS_CP3="10.0.0.12"

# Apply to second control plane
talosctl apply-config --insecure \
    --nodes $TALOS_CP2 \
    --file controlplane.yaml

# Apply to third control plane
talosctl apply-config --insecure \
    --nodes $TALOS_CP3 \
    --file controlplane.yaml
```

### Verify Control Plane HA

```bash
# Update endpoints to include all control planes
talosctl config endpoint $TALOS_CP1 $TALOS_CP2 $TALOS_CP3

# Check all nodes
talosctl health

# Verify etcd cluster
talosctl etcd members

# Check Kubernetes nodes
kubectl get nodes
# Should show 3 control plane nodes
```

---

## Part 5: Physical Worker Nodes

### Boot from USB

Same process as control plane:
1. Insert USB
2. Boot from USB
3. Wait for maintenance mode

### Apply Worker Configuration

```bash
export TALOS_W1="10.0.0.20"
export TALOS_W2="10.0.0.21"
export TALOS_W3="10.0.0.22"

# Apply worker config to each
talosctl apply-config --insecure \
    --nodes $TALOS_W1 \
    --file worker.yaml

talosctl apply-config --insecure \
    --nodes $TALOS_W2 \
    --file worker.yaml

talosctl apply-config --insecure \
    --nodes $TALOS_W3 \
    --file worker.yaml
```

### Verify Workers

```bash
# Check all nodes
kubectl get nodes -o wide

# Expected output:
# NAME            STATUS   ROLES           AGE   VERSION   INTERNAL-IP
# talos-cp-1      Ready    control-plane   10m   v1.31.0   10.0.0.10
# talos-cp-2      Ready    control-plane   8m    v1.31.0   10.0.0.11
# talos-cp-3      Ready    control-plane   8m    v1.31.0   10.0.0.12
# talos-worker-1  Ready    <none>          5m    v1.31.0   10.0.0.20
# talos-worker-2  Ready    <none>          5m    v1.31.0   10.0.0.21
# talos-worker-3  Ready    <none>          5m    v1.31.0   10.0.0.22
```

---

## Part 6: Post-Installation

### Install CNI (Cilium Recommended)

```bash
# Install Helm
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

# Verify pods are running
kubectl get pods -n kube-system
```

### Label Worker Nodes

```bash
kubectl label node talos-worker-1 node-role.kubernetes.io/worker=worker
kubectl label node talos-worker-2 node-role.kubernetes.io/worker=worker
kubectl label node talos-worker-3 node-role.kubernetes.io/worker=worker
```

### Install MetalLB (Load Balancer)

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Wait for pods
kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=90s

# Configure IP pool
cat <<EOF | kubectl apply -f -
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
```

---

## Troubleshooting

### Node Stuck in Maintenance Mode

```bash
# Check if config was applied
talosctl get machinestatus --nodes <IP>

# Re-apply config
talosctl apply-config --insecure --nodes <IP> --file <config>.yaml
```

### etcd Issues

```bash
# Check etcd health
talosctl etcd status --nodes $TALOS_CP1

# Force etcd recovery (DANGEROUS - data loss possible)
talosctl etcd forfeit-leadership --nodes <problem-node>
```

### Network Issues

```bash
# Check interfaces on node
talosctl get addresses --nodes <IP>

# Check routing
talosctl get routes --nodes <IP>

# Read logs
talosctl logs networkd --nodes <IP>
```

### Reset Node (Start Fresh)

```bash
# Wipe node completely
talosctl reset --nodes <IP> --graceful=false --reboot

# After reboot, re-apply config
talosctl apply-config --insecure --nodes <IP> --file <config>.yaml
```

---

## Backup & Recovery

### Backup Secrets

```bash
# Critical files to backup
cp secrets.yaml ~/secure-backup/
cp talosconfig ~/secure-backup/
cp controlplane.yaml ~/secure-backup/
cp worker.yaml ~/secure-backup/
```

### etcd Snapshot

```bash
# Create snapshot
talosctl etcd snapshot db.snapshot --nodes $TALOS_CP1

# Restore (on all control planes)
talosctl bootstrap --recover-from=db.snapshot --nodes $TALOS_CP1
```

---

## Quick Reference

```bash
# Set environment
export TALOSCONFIG="$HOME/homelab-talos/talosconfig"

# Node management
talosctl health                    # Check cluster health
talosctl dashboard                 # Interactive dashboard
talosctl dmesg -f --nodes <IP>    # Stream logs

# Kubernetes
talosctl kubeconfig -f ~/.kube/config  # Get kubeconfig
kubectl get nodes -o wide              # List nodes

# Upgrade
talosctl upgrade --nodes <IP> --image ghcr.io/siderolabs/installer:v1.9.0

# Reboot
talosctl reboot --nodes <IP>

# Shutdown
talosctl shutdown --nodes <IP>
```

---

## Network Reference

| Node | IP | MAC (set in OPNsense) | Role |
|------|----|-----------------------|------|
| VIP | 10.0.0.5 | - | API Server |
| talos-cp-1 | 10.0.0.10 | (from VM) | Control Plane |
| talos-cp-2 | 10.0.0.11 | (physical) | Control Plane |
| talos-cp-3 | 10.0.0.12 | (physical) | Control Plane |
| talos-worker-1 | 10.0.0.20 | (physical) | Worker |
| talos-worker-2 | 10.0.0.21 | (physical) | Worker |
| talos-worker-3 | 10.0.0.22 | (physical) | Worker |
| MetalLB Pool | 10.0.0.50-99 | - | LoadBalancer IPs |
