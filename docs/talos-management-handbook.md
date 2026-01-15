# Talos Linux Management Handbook

A practical reference guide for day-to-day management of Talos Linux Kubernetes clusters.

> [!TIP]
> For initial cluster setup, see [talos-setup-guide.md](talos-setup-guide.md)

---

## Table of Contents

- [Essential Commands](#essential-commands)
- [Cluster Health & Monitoring](#cluster-health--monitoring)
- [Configuration Management](#configuration-management)
- [Upgrades](#upgrades)
- [Node Operations](#node-operations)
- [etcd Operations](#etcd-operations)
- [Networking](#networking)
- [Storage](#storage)
- [Troubleshooting](#troubleshooting)
- [Disaster Recovery](#disaster-recovery)
- [Security](#security)
- [Official References](#official-references)

---

## Essential Commands

### Environment Setup

```bash
# Set talosconfig location (add to ~/.zshrc or ~/.bashrc)
export TALOSCONFIG="$HOME/homelab-talos/talosconfig"

# Configure endpoints (control plane IPs)
talosctl config endpoint 10.0.0.10 10.0.0.11 10.0.0.12

# Set default node to interact with
talosctl config node 10.0.0.10
```

### Quick Command Reference

| Command | Description |
|---------|-------------|
| `talosctl health` | Check cluster health |
| `talosctl dashboard` | Interactive TUI dashboard |
| `talosctl dashboard --nodes <ip>` | Dashboard for specific node |
| `talosctl version` | Show Talos and Kubernetes versions |
| `talosctl get members` | List cluster members |
| `talosctl kubeconfig` | Generate kubeconfig |

---

## Cluster Health & Monitoring

### Health Check

```bash
# Full cluster health check
talosctl health

# Health check with timeout
talosctl health --wait-timeout 5m

# Check specific node
talosctl health --nodes 10.0.0.10
```

### Dashboard

```bash
# Launch interactive dashboard
talosctl dashboard

# Dashboard for specific nodes
talosctl dashboard --nodes 10.0.0.10,10.0.0.11
```

The dashboard shows:
- **System**: CPU, Memory, Processes
- **Monitor**: Real-time metrics
- **Network**: Interface statistics
- **Processes**: Running processes
- **Summary**: Node information

### Logs

```bash
# Stream kernel logs
talosctl dmesg -f --nodes 10.0.0.10

# View service logs
talosctl logs kubelet --nodes 10.0.0.10
talosctl logs containerd --nodes 10.0.0.10
talosctl logs etcd --nodes 10.0.0.10

# Follow logs
talosctl logs kubelet -f --nodes 10.0.0.10

# Logs with timestamps
talosctl logs kubelet --tail 100 --nodes 10.0.0.10
```

### Services

```bash
# List all services
talosctl services --nodes 10.0.0.10

# Check specific service
talosctl service kubelet --nodes 10.0.0.10

# Restart a service
talosctl service kubelet restart --nodes 10.0.0.10
```

---

## Configuration Management

### View Current Configuration

```bash
# View machine config
talosctl get machineconfig --nodes 10.0.0.10 -o yaml

# View specific resources
talosctl get kubeletconfig --nodes 10.0.0.10
talosctl get etcdconfig --nodes 10.0.0.10
talosctl get networkconfig --nodes 10.0.0.10
```

### Apply Configuration Changes

```bash
# Apply full config
talosctl apply-config --nodes 10.0.0.10 --file controlplane.yaml

# Apply config without reboot (if possible)
talosctl apply-config --nodes 10.0.0.10 --file controlplane.yaml --mode no-reboot

# Apply config with auto mode (decides reboot automatically)
talosctl apply-config --nodes 10.0.0.10 --file controlplane.yaml --mode auto

# Dry-run to see what would change
talosctl apply-config --nodes 10.0.0.10 --file controlplane.yaml --dry-run
```

### Configuration Modes

| Mode | Description |
|------|-------------|
| `auto` | Automatically determines if reboot needed |
| `no-reboot` | Applies without reboot (may fail if reboot required) |
| `reboot` | Forces a reboot after applying |
| `staged` | Stages config for next reboot |

### Config Patches

```bash
# Apply a config patch
talosctl patch machineconfig --nodes 10.0.0.10 --patch-file patch.yaml

# Patch via command line
talosctl patch machineconfig --nodes 10.0.0.10 \
  --patch '[{"op": "add", "path": "/machine/network/hostname", "value": "new-hostname"}]'
```

---

## Upgrades

> [!WARNING]
> Always backup etcd before upgrading. Test upgrades on worker nodes first.

### Pre-Upgrade Checklist

1. Check current versions:
   ```bash
   talosctl version --nodes 10.0.0.10
   ```

2. Backup etcd:
   ```bash
   talosctl etcd snapshot etcd-backup-$(date +%Y%m%d).snapshot --nodes 10.0.0.10
   ```

3. Review [release notes](https://github.com/siderolabs/talos/releases)

### Upgrade Talos

```bash
# Check available versions
# Visit: https://github.com/siderolabs/talos/releases

# Upgrade single node
talosctl upgrade --nodes 10.0.0.10 \
  --image ghcr.io/siderolabs/installer:v1.9.1

# Upgrade with preserve (keeps data)
talosctl upgrade --nodes 10.0.0.10 \
  --image ghcr.io/siderolabs/installer:v1.9.1 \
  --preserve
```

### Upgrade Strategy

**Recommended order:**
1. Workers first (one at a time)
2. Control plane nodes (one at a time, ensuring etcd health between each)

```bash
# Upgrade workers
for node in 10.0.0.20 10.0.0.21 10.0.0.22; do
  echo "Upgrading $node..."
  talosctl upgrade --nodes $node --image ghcr.io/siderolabs/installer:v1.9.1
  echo "Waiting for node to be ready..."
  sleep 60
  talosctl health --nodes $node --wait-timeout 5m
done

# Upgrade control plane (one at a time!)
talosctl upgrade --nodes 10.0.0.10 --image ghcr.io/siderolabs/installer:v1.9.1
talosctl health --wait-timeout 5m
# Repeat for 10.0.0.11, then 10.0.0.12
```

### Upgrade Kubernetes

```bash
# Upgrade Kubernetes version
talosctl upgrade-k8s --nodes 10.0.0.10 --to 1.32.0
```

---

## Node Operations

### Reboot

```bash
# Graceful reboot (drains first in Kubernetes context)
talosctl reboot --nodes 10.0.0.10

# Force reboot (no drain)
talosctl reboot --nodes 10.0.0.10 --wait=false
```

### Shutdown

```bash
# Graceful shutdown
talosctl shutdown --nodes 10.0.0.10

# Force shutdown
talosctl shutdown --nodes 10.0.0.10 --force
```

### Reset Node

```bash
# Graceful reset (leaves etcd, wipes state)
talosctl reset --nodes 10.0.0.10 --graceful

# Full reset (removes from cluster)
talosctl reset --nodes 10.0.0.10 --graceful=false --reboot

# Reset with system disk wipe
talosctl reset --nodes 10.0.0.10 --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --reboot
```

### Adding New Nodes

```bash
# For a new worker
talosctl apply-config --insecure --nodes <new-node-ip> --file worker.yaml

# For a new control plane
talosctl apply-config --insecure --nodes <new-node-ip> --file controlplane.yaml
# Note: Do NOT run bootstrap on additional control planes
```

### Removing Nodes

```bash
# 1. Drain in Kubernetes
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Remove from etcd (control plane only)
talosctl etcd remove-member <member-id> --nodes 10.0.0.10

# 3. Reset the node
talosctl reset --nodes <node-ip>

# 4. Delete from Kubernetes
kubectl delete node <node-name>
```

---

## etcd Operations

### Health & Status

```bash
# List etcd members
talosctl etcd members --nodes 10.0.0.10

# Check etcd status
talosctl etcd status --nodes 10.0.0.10

# Get etcd alarms
talosctl etcd alarm list --nodes 10.0.0.10

# Disarm alarms
talosctl etcd alarm disarm --nodes 10.0.0.10
```

### Backup & Restore

```bash
# Create snapshot
talosctl etcd snapshot etcd-backup.snapshot --nodes 10.0.0.10

# Restore from snapshot (nuclear option - cluster recovery)
talosctl bootstrap --recover-from=etcd-backup.snapshot --nodes 10.0.0.10
```

### Member Management

```bash
# Forfeit leadership (useful before maintenance)
talosctl etcd forfeit-leadership --nodes 10.0.0.10

# Remove unhealthy member
talosctl etcd remove-member <member-id> --nodes <healthy-node>
```

> [!CAUTION]
> Never remove etcd members unless you have a healthy quorum. Losing quorum means cluster failure.

### etcd Quorum

| Total Members | Quorum Needed | Tolerable Failures |
|---------------|---------------|-------------------|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

---

## Networking

### View Network Configuration

```bash
# Get addresses
talosctl get addresses --nodes 10.0.0.10

# Get routes
talosctl get routes --nodes 10.0.0.10

# Get link status
talosctl get links --nodes 10.0.0.10

# Get network interfaces
talosctl get networkdevicespecs --nodes 10.0.0.10
```

### Connectivity Tests

```bash
# Check DNS resolution
talosctl get resolvers --nodes 10.0.0.10

# View hostname
talosctl get hostname --nodes 10.0.0.10

# Network diagnostics via logs
talosctl logs networkd --nodes 10.0.0.10
```

### VIP (Virtual IP) Status

```bash
# Check VIP status (who holds it)
talosctl get addressspecs --nodes 10.0.0.10
```

---

## Storage

### View Disks & Mounts

```bash
# List disks
talosctl disks --nodes 10.0.0.10

# List mounts
talosctl mounts --nodes 10.0.0.10

# Get disk partitions info
talosctl get volumestatus --nodes 10.0.0.10
```

### Disk Management

```bash
# View disk usage (via dashboard)
talosctl dashboard --nodes 10.0.0.10
```

---

## Troubleshooting

### Node Won't Boot / Stuck

```bash
# Check boot events
talosctl dmesg --nodes 10.0.0.10

# Check machine status
talosctl get machinestatus --nodes 10.0.0.10

# Check services
talosctl services --nodes 10.0.0.10
```

### Kubernetes API Unreachable

```bash
# Check kube-apiserver via talosctl
talosctl service kube-apiserver --nodes 10.0.0.10

# View apiserver logs
talosctl logs kube-apiserver --nodes 10.0.0.10

# Check certificates
talosctl get certificates --nodes 10.0.0.10
```

### etcd Issues

```bash
# Check etcd logs
talosctl logs etcd --nodes 10.0.0.10

# Verify members
talosctl etcd members --nodes 10.0.0.10

# Check for alarms
talosctl etcd alarm list --nodes 10.0.0.10
```

### Container Issues

```bash
# List containers
talosctl containers --nodes 10.0.0.10

# List containers in k8s namespace
talosctl containers --kubernetes --nodes 10.0.0.10

# Get container logs
talosctl logs -k <pod-namespace/pod-name> --nodes 10.0.0.10
```

### Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| Node stuck in maintenance | Re-apply config: `talosctl apply-config --insecure --file <config>.yaml --nodes <ip>` |
| etcd quorum lost | Restore from snapshot or recreate cluster |
| Certificate expired | Apply new config or upgrade Talos |
| VIP not working | Check firewall rules, VRRP configuration |
| Node not joining | Verify network, check bootstrap status |

---

## Disaster Recovery

### Full Cluster Recovery

> [!IMPORTANT]
> You need `secrets.yaml` and an etcd snapshot for recovery.

```bash
# 1. Boot nodes from Talos media (`--insecure` not yet configured)

# 2. Regenerate configs from secrets
talosctl gen config homelab-cluster https://10.0.0.5:6443 \
  --with-secrets secrets.yaml \
  --output-dir ./recovery

# 3. Apply config to first control plane
talosctl apply-config --insecure --nodes 10.0.0.10 --file recovery/controlplane.yaml

# 4. Bootstrap with etcd recovery
talosctl bootstrap --recover-from=etcd-backup.snapshot --nodes 10.0.0.10

# 5. Apply config to remaining nodes
talosctl apply-config --insecure --nodes 10.0.0.11 --file recovery/controlplane.yaml
talosctl apply-config --insecure --nodes 10.0.0.12 --file recovery/controlplane.yaml

# 6. Apply worker configs
talosctl apply-config --insecure --nodes 10.0.0.20 --file recovery/worker.yaml
# ... repeat for other workers
```

### Backup Checklist

| Item | Location | Backup Method |
|------|----------|---------------|
| `secrets.yaml` | `~/homelab-talos/` | Copy to secure storage |
| `talosconfig` | `~/homelab-talos/` | Copy to secure storage |
| `controlplane.yaml` | `~/homelab-talos/` | Copy to secure storage |
| `worker.yaml` | `~/homelab-talos/` | Copy to secure storage |
| etcd snapshot | Generated | `talosctl etcd snapshot` (schedule regular backups) |
| Kubernetes secrets | Cluster | Velero or similar backup tool |

---

## Security

### Rotate Certificates

Talos automatically rotates certificates. To manually regenerate:

```bash
# Generate new secrets (new cluster identity)
talosctl gen secrets -o new-secrets.yaml

# Regenerate configs
talosctl gen config homelab-cluster https://10.0.0.5:6443 \
  --with-secrets new-secrets.yaml \
  --output-dir ./new-config
```

### Access Control

```bash
# Generate new talosconfig with limited access
talosctl gen config homelab-cluster https://10.0.0.5:6443 \
  --with-secrets secrets.yaml \
  --output-types talosconfig
```

### Firewall Considerations

Required ports for Talos:

| Port | Protocol | Purpose |
|------|----------|---------|
| 50000 | TCP | Talos API (trustd) |
| 50001 | TCP | Talos API (apid) |
| 6443 | TCP | Kubernetes API |
| 2379-2380 | TCP | etcd client/peer |
| 10250 | TCP | Kubelet |

---

## Official References

### Documentation

- **Talos Documentation**: https://www.talos.dev/docs/
- **Getting Started**: https://www.talos.dev/docs/latest/introduction/getting-started/
- **Configuration Reference**: https://www.talos.dev/docs/latest/reference/configuration/v1alpha1/config/
- **CLI Reference**: https://www.talos.dev/docs/latest/reference/cli/

### GitHub & Community

- **GitHub Repository**: https://github.com/siderolabs/talos
- **Releases**: https://github.com/siderolabs/talos/releases
- **Slack Community**: https://slack.dev.talos-systems.io/
- **GitHub Discussions**: https://github.com/siderolabs/talos/discussions

### Related Tools

- **Omni** (Talos SaaS Management): https://www.siderolabs.com/platform/saas-for-kubernetes/
- **Image Factory** (Custom Images): https://factory.talos.dev/
- **Extensions**: https://github.com/siderolabs/extensions

### Kubernetes Resources

- **Kubernetes Documentation**: https://kubernetes.io/docs/
- **kubectl Cheat Sheet**: https://kubernetes.io/docs/reference/kubectl/cheatsheet/
- **Cilium (CNI)**: https://docs.cilium.io/
- **MetalLB**: https://metallb.universe.tf/

---

## Quick Reference Card

```text
┌─────────────────────────────────────────────────────────────┐
│                    TALOS QUICK REFERENCE                     │
├─────────────────────────────────────────────────────────────┤
│ HEALTH                                                       │
│   talosctl health              # Cluster health check        │
│   talosctl dashboard           # Interactive dashboard       │
│   talosctl services            # List services               │
├─────────────────────────────────────────────────────────────┤
│ LOGS                                                         │
│   talosctl dmesg -f            # Stream kernel logs          │
│   talosctl logs kubelet        # Kubelet logs                │
│   talosctl logs etcd           # etcd logs                   │
├─────────────────────────────────────────────────────────────┤
│ CONFIG                                                       │
│   talosctl apply-config        # Apply configuration         │
│   talosctl get machineconfig   # View current config         │
│   talosctl patch machineconfig # Patch config                │
├─────────────────────────────────────────────────────────────┤
│ OPERATIONS                                                   │
│   talosctl upgrade             # Upgrade Talos               │
│   talosctl reboot              # Reboot node                 │
│   talosctl shutdown            # Shutdown node               │
│   talosctl reset               # Reset node                  │
├─────────────────────────────────────────────────────────────┤
│ ETCD                                                         │
│   talosctl etcd members        # List members                │
│   talosctl etcd status         # etcd status                 │
│   talosctl etcd snapshot       # Create snapshot             │
├─────────────────────────────────────────────────────────────┤
│ KUBERNETES                                                   │
│   talosctl kubeconfig          # Get kubeconfig              │
│   talosctl containers -k       # List k8s containers         │
└─────────────────────────────────────────────────────────────┘
```

---

*Last updated: 2026-01-15*
