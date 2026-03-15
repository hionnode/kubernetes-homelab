# Ephemeral Sandboxes on Talos

**Date:** 2026-03-15
**Purpose:** Guide for creating short-lived, isolated Kubernetes environments on the Talos homelab cluster for development, testing, experimentation, and CI workloads.

---

## Overview

Ephemeral sandboxes are disposable environments that can be spun up quickly, used for a specific purpose, and torn down without affecting the production cluster state. On a Talos-based homelab, there are several approaches — from lightweight namespace isolation to full throwaway clusters.

This guide covers three tiers of isolation, from lightest to heaviest:

| Tier | Approach | Isolation Level | Spin-up Time | Use Cases |
|------|----------|----------------|-------------|-----------|
| 1 | Namespace + RBAC | Logical | Seconds | Feature dev, app testing, demos |
| 2 | vcluster (virtual cluster) | Strong | ~30 seconds | Multi-tenant dev, CRD testing, upgrade dry-runs |
| 3 | Disposable Talos VM cluster | Full | ~5 minutes | Talos upgrades, CNI experiments, destructive testing |

---

## Tier 1: Namespace-Based Sandboxes

The simplest approach — create an isolated namespace with resource quotas, network policies, and a dedicated service account. Best for application-level development where you trust the cluster configuration.

### Create a Sandbox Namespace

```bash
# Create sandbox with a TTL label for cleanup
kubectl create namespace sandbox-$(whoami)-$(date +%s)

# Or use a deterministic name
export SANDBOX_NS="sandbox-dev"
kubectl create namespace $SANDBOX_NS
kubectl label namespace $SANDBOX_NS sandbox=true ttl=24h
```

### Apply Resource Quotas

Prevent sandboxes from starving production workloads:

```yaml
# sandbox-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: sandbox-quota
  namespace: sandbox-dev
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "20"
    services.loadbalancers: "2"
    persistentvolumeclaims: "5"
```

```bash
kubectl apply -f sandbox-quota.yaml
```

### Apply Network Policy

Isolate sandbox traffic from production namespaces:

```yaml
# sandbox-netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sandbox-isolation
  namespace: sandbox-dev
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic within the sandbox namespace
    - from:
        - podSelector: {}
  egress:
    # Allow DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    # Allow traffic within the sandbox namespace
    - to:
        - podSelector: {}
    # Allow external egress (internet)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/24  # Block access to LAN
```

```bash
kubectl apply -f sandbox-netpol.yaml
```

### Scoped Kubeconfig

Generate a kubeconfig locked to the sandbox namespace:

```bash
# Create service account
kubectl -n $SANDBOX_NS create serviceaccount sandbox-user

# Create role with full namespace access
kubectl -n $SANDBOX_NS create rolebinding sandbox-admin \
  --clusterrole=admin \
  --serviceaccount=$SANDBOX_NS:sandbox-user

# Generate a token
kubectl -n $SANDBOX_NS create token sandbox-user --duration=24h
```

### Teardown

```bash
kubectl delete namespace $SANDBOX_NS
```

### Automated Cleanup with CronJob

Deploy a reaper that deletes expired sandbox namespaces:

```yaml
# sandbox-reaper.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: sandbox-reaper
  namespace: kube-system
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: sandbox-reaper
          containers:
            - name: reaper
              image: bitnami/kubectl:latest
              command:
                - /bin/sh
                - -c
                - |
                  # Delete namespaces labeled sandbox=true older than 24h
                  kubectl get ns -l sandbox=true -o json | \
                  jq -r '.items[] |
                    select(.metadata.creationTimestamp |
                      fromdateiso8601 < (now - 86400)) |
                    .metadata.name' | \
                  xargs -r -I{} kubectl delete ns {}
          restartPolicy: OnFailure
```

---

## Tier 2: Virtual Clusters (vcluster)

[vcluster](https://www.vcluster.com/) runs a lightweight Kubernetes control plane inside a namespace of the host cluster. Each vcluster gets its own API server, etcd (or SQLite), and scheduler — but pods are scheduled on the host cluster's nodes. This gives near-full cluster isolation without additional VMs.

### Why vcluster on Talos

- **CRD isolation**: Install any CRDs without affecting the host cluster
- **Version testing**: Run a different Kubernetes version inside the vcluster
- **Admin access**: Full cluster-admin without risk to the host
- **Cheap**: Uses ~256 MB RAM for the control plane
- **Fast**: Ready in ~30 seconds

### Install vcluster CLI

```bash
# macOS
brew install loft-sh/tap/vcluster

# Or direct download
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-darwin-arm64"
chmod +x vcluster && sudo mv vcluster /usr/local/bin/
```

### Create a Virtual Cluster

```bash
# Create a vcluster in its own namespace
vcluster create dev-sandbox \
  --namespace vcluster-dev-sandbox \
  --connect=false

# Connect to it (switches kubeconfig context)
vcluster connect dev-sandbox --namespace vcluster-dev-sandbox

# Verify — you're now inside the virtual cluster
kubectl get nodes
kubectl get ns
```

### vcluster with Custom K8s Version

Test workloads against a different Kubernetes version:

```bash
vcluster create k8s-upgrade-test \
  --namespace vcluster-upgrade-test \
  --kubernetes-version v1.32.0 \
  --connect=false
```

### vcluster with Resource Limits

Constrain the virtual cluster's footprint:

```yaml
# vcluster-values.yaml
syncer:
  resources:
    limits:
      cpu: "1"
      memory: 512Mi

controlPlane:
  backingStore:
    etcd:
      embedded:
        enabled: true  # Use embedded etcd (lighter than deploying a separate etcd)
  distro:
    k8s:
      enabled: true

sync:
  toHost:
    persistentVolumes:
      enabled: true
```

```bash
vcluster create dev-sandbox \
  --namespace vcluster-dev-sandbox \
  --values vcluster-values.yaml \
  --connect=false
```

### Working with vcluster

```bash
# List active virtual clusters
vcluster list

# Disconnect (switch back to host context)
vcluster disconnect

# Pause (scale down control plane, saves resources)
vcluster pause dev-sandbox -n vcluster-dev-sandbox

# Resume
vcluster resume dev-sandbox -n vcluster-dev-sandbox

# Delete
vcluster delete dev-sandbox -n vcluster-dev-sandbox
```

### Exposing Services from vcluster

Services inside vcluster can be exposed via the host cluster's MetalLB:

```bash
# Inside the vcluster
kubectl expose deployment my-app --type=LoadBalancer --port=80

# MetalLB on the host cluster assigns an IP from 10.0.0.50-99
kubectl get svc my-app
```

---

## Tier 3: Disposable Talos VM Clusters

For scenarios requiring full infrastructure isolation — Talos version upgrades, CNI swaps, kernel parameter testing, or destructive experimentation — spin up an entirely separate Talos cluster on Proxmox.

### Prerequisites

- Proxmox access with permissions to create VMs
- Talos ISO already uploaded to Proxmox (`/var/lib/vz/template/iso/talos-amd64.iso`)
- Sufficient resources on Proxmox host (each sandbox node: 2 CPU, 2 GB RAM, 16 GB disk)

### Create VMs with a Script

```bash
#!/usr/bin/env bash
# scripts/create-sandbox-cluster.sh
# Creates a minimal throwaway Talos cluster on Proxmox
set -euo pipefail

SANDBOX_NAME="${1:?Usage: $0 <sandbox-name>}"
VMID_START="${2:-300}"  # Start VM IDs at 300+ to avoid conflicts
NUM_NODES="${3:-1}"     # Default: single-node cluster
TALOS_VERSION="${TALOS_VERSION:-v1.9.0}"

PROXMOX_HOST="192.168.1.110"
BRIDGE="vmbr1"
ISO="local:iso/talos-amd64.iso"

echo "Creating sandbox cluster: $SANDBOX_NAME"
echo "  Nodes: $NUM_NODES (VMIDs $VMID_START - $((VMID_START + NUM_NODES - 1)))"

for i in $(seq 0 $((NUM_NODES - 1))); do
  VMID=$((VMID_START + i))
  NAME="${SANDBOX_NAME}-node-${i}"

  echo "Creating VM $VMID ($NAME)..."
  ssh root@${PROXMOX_HOST} qm create $VMID \
    --name "$NAME" \
    --tags "sandbox,${SANDBOX_NAME}" \
    --cores 2 \
    --memory 2048 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsi0 "local-lvm:16" \
    --ide2 "${ISO},media=cdrom" \
    --boot "order=ide2" \
    --ostype l26 \
    --agent 0

  ssh root@${PROXMOX_HOST} qm start $VMID
  echo "  VM $VMID started."
done

echo ""
echo "Sandbox cluster '$SANDBOX_NAME' created."
echo "Wait for nodes to boot into Talos maintenance mode, then:"
echo "  1. Check OPNsense DHCP leases for assigned IPs"
echo "  2. Generate configs:  talosctl gen config ${SANDBOX_NAME} https://<NODE_IP>:6443"
echo "  3. Apply config:     talosctl apply-config --insecure --nodes <IP> --file controlplane.yaml"
echo "  4. Bootstrap:        talosctl bootstrap --nodes <IP>"
```

### Bootstrap the Sandbox Cluster

```bash
# Generate separate secrets for this sandbox (never reuse production secrets)
talosctl gen secrets -o /tmp/${SANDBOX_NAME}-secrets.yaml

# Generate configs — single-node setup allows scheduling on control plane
talosctl gen config ${SANDBOX_NAME} https://${NODE_IP}:6443 \
  --with-secrets /tmp/${SANDBOX_NAME}-secrets.yaml \
  --output-dir /tmp/${SANDBOX_NAME}-configs \
  --config-patch '[{"op": "add", "path": "/cluster/allowSchedulingOnControlPlanes", "value": true}]'

# Apply and bootstrap
talosctl apply-config --insecure --nodes ${NODE_IP} \
  --file /tmp/${SANDBOX_NAME}-configs/controlplane.yaml
talosctl --talosconfig /tmp/${SANDBOX_NAME}-configs/talosconfig \
  config endpoint ${NODE_IP}
talosctl --talosconfig /tmp/${SANDBOX_NAME}-configs/talosconfig \
  bootstrap --nodes ${NODE_IP}

# Get kubeconfig
talosctl --talosconfig /tmp/${SANDBOX_NAME}-configs/talosconfig \
  kubeconfig /tmp/${SANDBOX_NAME}-kubeconfig --nodes ${NODE_IP}
export KUBECONFIG=/tmp/${SANDBOX_NAME}-kubeconfig
kubectl get nodes
```

### Tear Down the Sandbox Cluster

```bash
#!/usr/bin/env bash
# scripts/destroy-sandbox-cluster.sh
set -euo pipefail

SANDBOX_NAME="${1:?Usage: $0 <sandbox-name>}"
PROXMOX_HOST="192.168.1.110"

echo "Destroying sandbox cluster: $SANDBOX_NAME"

# Find VMs with the sandbox tag
VMIDS=$(ssh root@${PROXMOX_HOST} \
  "qm list | grep '${SANDBOX_NAME}' | awk '{print \$1}'")

for VMID in $VMIDS; do
  echo "Stopping and destroying VM $VMID..."
  ssh root@${PROXMOX_HOST} "qm stop $VMID 2>/dev/null; qm destroy $VMID --purge"
done

# Clean up local configs
rm -rf /tmp/${SANDBOX_NAME}-*

echo "Sandbox cluster '$SANDBOX_NAME' destroyed."
```

### Terraform Alternative

For a more repeatable approach, create a Terraform module:

```hcl
# terraform/modules/sandbox-cluster/main.tf
variable "name" {
  description = "Sandbox cluster name"
  type        = string
}

variable "node_count" {
  description = "Number of nodes"
  type        = number
  default     = 1
}

variable "vmid_start" {
  description = "Starting VM ID"
  type        = number
  default     = 300
}

resource "proxmox_virtual_environment_vm" "sandbox_node" {
  count     = var.node_count
  name      = "${var.name}-node-${count.index}"
  node_name = "pve"
  vm_id     = var.vmid_start + count.index
  tags      = ["sandbox", var.name]

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    size         = 16
    interface    = "scsi0"
  }

  cdrom {
    enabled   = true
    file_id   = "local:iso/talos-amd64.iso"
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}

output "vm_ids" {
  value = proxmox_virtual_environment_vm.sandbox_node[*].vm_id
}
```

Usage:

```bash
cd terraform
terraform apply -target=module.sandbox -var='name=upgrade-test' -var='node_count=1'
# ... experiment ...
terraform destroy -target=module.sandbox
```

---

## Choosing the Right Tier

```
Do you need cluster-admin or custom CRDs?
├── No  → Tier 1 (Namespace)
└── Yes
    ├── Is app-level isolation enough?
    │   └── Yes → Tier 2 (vcluster)
    └── Do you need to test Talos itself, CNI, or node-level config?
        └── Yes → Tier 3 (Disposable VM cluster)
```

### Common Scenarios

| Scenario | Recommended Tier | Why |
|----------|-----------------|-----|
| Testing a new Helm chart | 1 (Namespace) | No cluster-level changes needed |
| Developing a custom operator | 2 (vcluster) | Needs CRDs, full API access |
| Testing ArgoCD ApplicationSets | 2 (vcluster) | Needs ArgoCD installed, isolated from prod |
| Dry-running a Talos upgrade | 3 (VM cluster) | Must test actual Talos machine config changes |
| Experimenting with Cilium policies | 2 or 3 | Tier 2 for L7 policies; Tier 3 if changing CNI install |
| CI/CD pipeline environments | 2 (vcluster) | Fast spin-up, good isolation, low resource cost |
| Load testing / chaos engineering | 3 (VM cluster) | Destructive by nature, needs full isolation |
| Demoing to a colleague | 1 (Namespace) | Quick, no setup overhead |

---

## Best Practices

1. **Never reuse production secrets** for sandbox clusters (Tier 3). Always generate fresh secrets with `talosctl gen secrets`.

2. **Set TTLs on everything.** Label namespaces and VMs with expiry metadata. Run automated reapers.

3. **Use dedicated VMID ranges.** Production VMs use 100-199, sandbox VMs use 300+. This prevents ID collisions and makes cleanup obvious.

4. **Reserve a MetalLB sub-range for sandboxes.** For example, split the pool:
   - Production: `10.0.0.50-10.0.0.74`
   - Sandboxes: `10.0.0.75-10.0.0.99`

5. **Clean up aggressively.** Sandbox VMs left running waste RAM/CPU on the Proxmox host. Set calendar reminders or automate cleanup.

6. **Document experiments.** Log sandbox activity in `docs/progress_log.md` so the team knows what was tested and what was learned.

---

## Integration with ArgoCD

Once ArgoCD is running, you can create an `ApplicationSet` that automatically provisions sandbox environments from Git branches:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: sandbox-environments
  namespace: argocd
spec:
  generators:
    - pullRequest:
        github:
          owner: hionnode
          repo: kubernetes-homelab
          labels:
            - sandbox
  template:
    metadata:
      name: "sandbox-{{branch}}"
    spec:
      project: sandboxes
      source:
        repoURL: https://github.com/hionnode/kubernetes-homelab.git
        targetRevision: "{{branch}}"
        path: k8s/sandbox
      destination:
        server: https://kubernetes.default.svc
        namespace: "sandbox-{{branch}}"
      syncPolicy:
        automated:
          selfHeal: true
          prune: true
        syncOptions:
          - CreateNamespace=true
```

This creates a sandbox namespace for every PR labeled `sandbox` and tears it down when the PR is closed.

---

## Reference

| Resource | Link |
|----------|------|
| vcluster docs | https://www.vcluster.com/docs |
| Talos getting started | https://www.talos.dev/latest/introduction/getting-started/ |
| Proxmox VM management | https://pve.proxmox.com/pve-docs/qm.1.html |
| Cilium network policies | https://docs.cilium.io/en/stable/network/kubernetes/policy/ |
| Existing cluster setup | [talos-setup-guide.md](talos-setup-guide.md) |
| Cluster implementation | [cluster-implementation-walkthrough.md](cluster-implementation-walkthrough.md) |
