# OpenBao Setup Guide

Secrets management for the homelab cluster using OpenBao (open-source Vault fork) in standalone mode with integrated Raft storage.

- **Architecture:** Standalone (single replica), Raft storage, no TLS (private LAN)
- **Access:** `http://10.0.0.51:8200` via MetalLB LoadBalancer
- **Namespace:** `openbao`

## Prerequisites

- Cluster bootstrapped with Cilium CNI
- MetalLB installed and configured (IP pool 10.0.0.50-99)
- `bao` CLI installed locally (`brew install openbao` or download from [openbao.org](https://openbao.org))

## Deploy

```bash
# Add Helm repo
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update

# Install
helm install openbao openbao/openbao \
  --namespace openbao --create-namespace \
  -f kubernetes/infrastructure/openbao/values.yaml

# Wait for pod (will be 0/1 Running until initialized)
kubectl -n openbao get pods -w
```

## Initialize

```bash
export BAO_ADDR="http://10.0.0.51:8200"

# Check status (should show Initialized: false)
bao status

# Initialize with single key share (simple for homelab)
bao operator init -key-shares=1 -key-threshold=1
```

**Save the unseal key and root token in a password manager. Do NOT commit them to Git.**

## Unseal

Required after every pod restart:

```bash
export BAO_ADDR="http://10.0.0.51:8200"
bao operator unseal <unseal-key>
```

## Post-Init Configuration

```bash
# Login
bao login <root-token>

# Enable KV v2 secrets engine
bao secrets enable -path=secret kv-v2

# Enable Kubernetes auth
bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create a read-only policy
bao policy write read-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read", "list"]
}
EOF

# Create a role (example: default SA in default namespace)
bao write auth/kubernetes/role/default \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=read-secrets \
  ttl=1h

# Verify with a test secret
bao kv put secret/test message="openbao is working"
bao kv get secret/test
```

## Create Admin Token and Revoke Root

```bash
bao policy write admin - <<EOF
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

bao token create -policy=admin -period=720h
# Save this token — use it for day-to-day admin

bao token revoke <root-token>
```

## ArgoCD Adoption

After ArgoCD is running, apply the Application manifest to manage OpenBao via GitOps:

```bash
kubectl apply -f kubernetes/argocd/applications/openbao.yaml
```

**Do not enable automated sync with selfHeal** — a sync that restarts the pod requires manual unsealing.

## Backup (Raft Snapshots)

```bash
# Take a snapshot
bao operator raft snapshot save backup-$(date +%Y%m%d-%H%M%S).snap

# Push to S3 (same bucket as Terraform state)
aws s3 cp backup-*.snap s3://<your-bucket>/openbao-backups/

# Restore (disaster recovery)
bao operator raft snapshot restore <snapshot-file>.snap
```

Run backups after any significant policy or secret changes. For automation, create a Kubernetes CronJob.

## Upgrade

```bash
# Update chart version in kubernetes/argocd/applications/openbao.yaml
# Then sync via ArgoCD (manual sync), or:
helm upgrade openbao openbao/openbao \
  --namespace openbao \
  -f kubernetes/infrastructure/openbao/values.yaml

# Unseal after upgrade (pod restarts)
bao operator unseal <unseal-key>
```

## Future Enhancements

- **External Secrets Operator (ESO):** Deploy when apps need secrets injected as native K8s Secrets. ESO uses the Vault provider (API-compatible with OpenBao).
- **Auto-unseal:** Store unseal key in a K8s Secret + CronJob if manual unseal becomes tedious.
- **TLS:** Add cert-manager certificates when an ingress controller is deployed.
- **CSI driver:** Enable in values.yaml for apps that need file-based secret injection.
