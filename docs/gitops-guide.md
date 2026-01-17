# GitOps Guide

A comprehensive guide to understanding and implementing GitOps principles for Kubernetes infrastructure and application delivery.

> [!TIP]
> For ArgoCD setup, see [argocd-setup-guide.md](argocd-setup-guide.md)

---

## Table of Contents

- [What is GitOps?](#what-is-gitops)
- [Core Principles](#core-principles)
- [GitOps for Our Homelab](#gitops-for-our-homelab)
- [GitOps vs Traditional CI/CD](#gitops-vs-traditional-cicd)
- [GitOps Architecture](#gitops-architecture)
- [Repository Strategies](#repository-strategies)
- [Directory Structure](#directory-structure)
- [Deployment Strategies](#deployment-strategies)
- [Secrets Management](#secrets-management)
- [Multi-Environment Management](#multi-environment-management)
- [GitOps Workflow Examples](#gitops-workflow-examples)
- [Tools Ecosystem](#tools-ecosystem)
- [Best Practices](#best-practices)
- [Official References](#official-references)

---

## What is GitOps?

GitOps is an operational framework that takes DevOps best practices for application development—version control, collaboration, compliance, and CI/CD—and applies them to infrastructure automation.

### Key Definition

> **GitOps** = Infrastructure as Code + Merge Requests + CI/CD

Git serves as the **single source of truth** for declarative infrastructure and applications. Changes are made via Git commits, and an automated process ensures the live system matches the desired state in Git.

### Core Benefits

| Benefit | Description |
|---------|-------------|
| **Auditability** | Complete history of all changes in Git |
| **Reproducibility** | Any state can be recreated from Git history |
| **Reliability** | Automated reconciliation prevents drift |
| **Security** | No direct cluster access needed for deployments |
| **Speed** | Faster deployments through automation |
| **Rollback** | Simple rollback via Git revert |

---

## Core Principles

### 1. Declarative Configuration

Everything is described declaratively—the desired state, not the steps to achieve it.

```yaml
# Declarative: What you want
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  
# NOT imperative: How to do it
# kubectl scale deployment my-app --replicas=3
```

### 2. Git as Single Source of Truth

All configuration lives in Git. The Git repository defines the desired state of the entire system.

```text
┌─────────────────────────────────────────────────────────┐
│                     GIT REPOSITORY                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   Apps      │  │  Infra      │  │  Config     │     │
│  │  Manifests  │  │  Manifests  │  │  Files      │     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
│                    SINGLE SOURCE OF TRUTH                │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │   KUBERNETES CLUSTER    │
              │    (Actual State)       │
              └─────────────────────────┘
```

### 3. Changes via Pull Requests

All changes go through pull requests, enabling:
- Code review
- Approval workflows
- Automated testing
- Audit trail

### 4. Automated Reconciliation

A GitOps operator continuously compares actual state with desired state and corrects any drift.

```text
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Desired    │     │   GitOps    │     │   Actual    │
│   State     │────▶│  Operator   │────▶│   State     │
│   (Git)     │     │ (ArgoCD/    │     │ (Cluster)   │
│             │     │  Flux)      │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       └───────────────────┼───────────────────┘
                           │
                    Continuous
                  Reconciliation
```

---

## GitOps for Our Homelab

This section covers implementing GitOps specifically for our Talos Kubernetes homelab with Proxmox and OPNsense.

### Our GitOps-Managed Stack

```text
┌─────────────────────────────────────────────────────────────────┐
│                HOMELAB GITOPS STACK                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  INFRASTRUCTURE LAYER (Terraform + Ansible)                     │
│  ├── Proxmox VMs (OPNsense, Talos CP-1)                         │
│  ├── OPNsense Configuration (DHCP, Firewall, NAT)               │
│  └── Talos Machine Configs                                     │
│                                                                  │
│  KUBERNETES LAYER (ArgoCD GitOps)                               │
│  ├── Cilium CNI                                                 │
│  ├── MetalLB (10.0.0.50-99)                                     │
│  ├── cert-manager                                               │
│  ├── Monitoring (Prometheus, Grafana, Loki)                     │
│  └── Applications                                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Recommended Repository Structure for Homelab

```text
kubernetes-homelab/
├── terraform/                  # Infrastructure as Code
│   ├── vm_opnsense.tf         # OPNsense VM definition
│   ├── cluster_talos.tf       # Talos VM definitions
│   └── variables.tf
│
├── ansible/                    # Configuration Management
│   └── opnsense/              # OPNsense automation
│
├── kubernetes/                 # GitOps-managed K8s resources
│   ├── argocd/                # ArgoCD configuration
│   │   ├── install.yaml       # ArgoCD installation manifest
│   │   └── app-of-apps.yaml   # Root application
│   │
│   ├── infrastructure/        # Cluster components
│   │   ├── cilium/
│   │   ├── metallb/
│   │   │   ├── namespace.yaml
│   │   │   ├── ipaddresspool.yaml  # 10.0.0.50-99
│   │   │   └── l2advertisement.yaml
│   │   └── cert-manager/
│   │
│   ├── monitoring/            # Observability stack
│   │   ├── prometheus/
│   │   ├── grafana/
│   │   └── loki/
│   │
│   └── apps/                  # Your applications
│       ├── homepage/
│       ├── nextcloud/
│       └── media-server/
│
├── docs/                       # Documentation
│   ├── argocd-setup-guide.md
│   ├── gitops-guide.md
│   └── talos-setup-guide.md
│
└── scripts/                    # Utility scripts
```

### Homelab App of Apps Example

```yaml
# kubernetes/argocd/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homelab-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/kubernetes-homelab.git
    targetRevision: main
    path: kubernetes/argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Infrastructure Applications

```yaml
# kubernetes/argocd/applications/metallb.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/kubernetes-homelab.git
    targetRevision: main
    path: kubernetes/infrastructure/metallb
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### Why GitOps Works Well for Homelab

| Homelab Challenge | GitOps Solution |
|-------------------|----------------|
| Talos has no SSH | Everything deployed via K8s manifests |
| Disaster recovery | Clone repo + `kubectl apply` = cluster restored |
| Experimenting safely | Feature branches for testing |
| Keeping track of changes | Git history shows all modifications |
| Sharing configs | Public/private repo for community |

### Homelab GitOps Workflow

```text
1. Edit manifests locally (VSCode, etc.)
         │
         ▼
2. Commit and push to GitHub
         │
         ▼
3. ArgoCD detects changes (polling or webhook)
         │
         ▼
4. ArgoCD syncs to Talos cluster (10.0.0.5:6443)
         │
         ▼
5. Workloads deployed to worker nodes (10.0.0.20-22)
         │
         ▼
6. Services get MetalLB IPs (10.0.0.50-99)
```

> [!TIP]
> For initial cluster bootstrap before ArgoCD is installed, use `kubectl apply -f kubernetes/infrastructure/` directly.

---

## GitOps vs Traditional CI/CD

### Traditional CI/CD (Push-based)

```text
Developer ─▶ Git Push ─▶ CI Pipeline ─▶ Build ─▶ Push to Cluster
                                                       │
                                              kubectl apply
```

**Characteristics:**
- CI system has cluster credentials
- Push-based deployment
- Harder to audit
- Manual drift detection

### GitOps (Pull-based)

```text
Developer ─▶ Git Push ─▶ Git Repository
                              │
                              ▼ (Pull)
                      GitOps Operator ─▶ Cluster
```

**Characteristics:**
- Operator runs inside cluster
- Pull-based deployment
- Complete audit trail
- Automatic drift correction

### Comparison Table

| Aspect | Traditional CI/CD | GitOps |
|--------|-------------------|--------|
| Deployment Model | Push | Pull |
| Credentials | CI has cluster access | Operator has cluster access |
| Drift Detection | Manual | Automatic |
| Rollback | Run new pipeline | Git revert |
| Audit Trail | CI logs | Git history |
| State Recovery | Rebuild pipeline | Sync from Git |

---

## GitOps Architecture

### Components

```text
┌────────────────────────────────────────────────────────────────┐
│                        DEVELOPER WORKFLOW                        │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                  │
│  │ Feature  │───▶│   PR /   │───▶│  Merge   │                  │
│  │  Branch  │    │  Review  │    │ to Main  │                  │
│  └──────────┘    └──────────┘    └──────────┘                  │
│                                        │                         │
└────────────────────────────────────────┼─────────────────────────┘
                                         ▼
┌────────────────────────────────────────────────────────────────┐
│                        GIT REPOSITORIES                          │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────┐         ┌─────────────────┐               │
│  │   Application   │         │  Infrastructure │               │
│  │   Source Code   │         │   Manifests     │               │
│  │   Repository    │         │   Repository    │               │
│  └────────┬────────┘         └────────┬────────┘               │
│           │                           │                          │
│           ▼                           │                          │
│  ┌─────────────────┐                  │                          │
│  │   CI Pipeline   │                  │                          │
│  │  (Build/Test)   │                  │                          │
│  └────────┬────────┘                  │                          │
│           │                           │                          │
│           ▼                           │                          │
│  ┌─────────────────┐                  │                          │
│  │ Container Image │                  │                          │
│  │    Registry     │                  │                          │
│  └────────┬────────┘                  │                          │
│           │                           │                          │
│           └──────────▶┌───────────────┴──────┐                  │
│                       │  Update Image Tag    │                  │
│                       │  in Config Repo      │                  │
│                       └──────────────────────┘                  │
└────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
┌────────────────────────────────────────────────────────────────┐
│                      KUBERNETES CLUSTER                          │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────┐         ┌─────────────────┐               │
│  │  GitOps Agent   │◀────────│  Git Repository │               │
│  │ (ArgoCD/Flux)   │  Poll   │   (Config)      │               │
│  └────────┬────────┘         └─────────────────┘               │
│           │                                                      │
│           ▼ Apply                                                │
│  ┌─────────────────────────────────────┐                        │
│  │         Kubernetes Resources         │                        │
│  │  ┌─────────┐ ┌─────────┐ ┌────────┐ │                        │
│  │  │  Pods   │ │Services │ │ConfigM.│ │                        │
│  │  └─────────┘ └─────────┘ └────────┘ │                        │
│  └─────────────────────────────────────┘                        │
└────────────────────────────────────────────────────────────────┘
```

---

## Repository Strategies

### Monorepo

All applications and infrastructure in a single repository.

```text
monorepo/
├── apps/
│   ├── frontend/
│   ├── backend/
│   └── database/
├── infrastructure/
│   ├── base/
│   └── overlays/
└── argocd/
    └── applications/
```

**Pros:** Atomic changes, easier refactoring, single CI/CD  
**Cons:** Large repo, permission complexity, slower CI

### Polyrepo

Separate repositories for applications and infrastructure.

```text
org/
├── app-frontend/          # App source + Dockerfile
├── app-backend/           # App source + Dockerfile
├── gitops-config/         # All Kubernetes manifests
└── gitops-infrastructure/ # Cluster-level resources
```

**Pros:** Clear ownership, faster CI, granular permissions  
**Cons:** Cross-repo changes harder, dependency management

### Hybrid (Recommended)

App source in separate repos, all configs in a dedicated GitOps repo.

```text
# Source repositories (CI builds here)
org/frontend-app/
org/backend-app/

# GitOps configuration repository (CD happens here)
org/gitops-config/
├── apps/
│   ├── frontend/
│   └── backend/
├── infrastructure/
└── clusters/
    ├── dev/
    ├── staging/
    └── production/
```

---

## Directory Structure

### Kustomize-based Structure

```text
gitops-config/
├── base/                          # Shared base configurations
│   ├── frontend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── backend/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── kustomization.yaml
│
├── overlays/                      # Environment-specific overrides
│   ├── dev/
│   │   ├── frontend/
│   │   │   ├── kustomization.yaml
│   │   │   └── replica-patch.yaml
│   │   └── backend/
│   │       └── kustomization.yaml
│   ├── staging/
│   └── production/
│
├── infrastructure/                # Cluster infrastructure
│   ├── cert-manager/
│   ├── ingress-nginx/
│   └── monitoring/
│
└── clusters/                      # Cluster-specific configs
    ├── dev-cluster/
    │   └── kustomization.yaml
    └── prod-cluster/
        └── kustomization.yaml
```

### Helm-based Structure

```text
gitops-config/
├── charts/                        # Custom Helm charts
│   ├── my-app/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   └── shared-lib/
│
├── releases/                      # Helm releases per environment
│   ├── dev/
│   │   ├── frontend.yaml
│   │   └── backend.yaml
│   ├── staging/
│   └── production/
│
└── infrastructure/
    ├── cert-manager/
    └── monitoring/
```

---

## Deployment Strategies

### Rolling Update (Default)

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
```

### Blue-Green Deployment

```text
┌─────────────────┐     ┌─────────────────┐
│   Blue (v1)     │     │  Green (v2)     │
│   (Current)     │     │   (New)         │
└────────┬────────┘     └────────┬────────┘
         │                       │
         │    ┌─────────┐        │
         └───▶│ Service │◀───────┘
              │(Switch) │
              └─────────┘
```

### Canary Deployment

```yaml
# With Argo Rollouts
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  strategy:
    canary:
      steps:
      - setWeight: 10
      - pause: {duration: 5m}
      - setWeight: 50
      - pause: {duration: 10m}
      - setWeight: 100
```

---

## Secrets Management

> [!CAUTION]
> Never commit plain-text secrets to Git repositories!

### Option 1: Sealed Secrets

```bash
# Install sealed-secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Encrypt secret
kubeseal --format yaml < secret.yaml > sealed-secret.yaml

# Commit sealed-secret.yaml (safe to store in Git)
```

### Option 2: External Secrets Operator

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: my-secret
  data:
  - secretKey: password
    remoteRef:
      key: secret/myapp
      property: password
```

### Option 3: SOPS (Mozilla)

```bash
# Encrypt with SOPS
sops --encrypt --age <PUBLIC_KEY> secrets.yaml > secrets.enc.yaml

# Decrypt automatically with ArgoCD SOPS plugin
```

### Comparison

| Tool | Storage | Complexity | GitOps Native |
|------|---------|------------|---------------|
| Sealed Secrets | Git (encrypted) | Low | Yes |
| External Secrets | External vault | Medium | Yes |
| SOPS | Git (encrypted) | Medium | Yes |
| Vault Agent | HashiCorp Vault | High | Partial |

---

## Multi-Environment Management

### Environment Promotion Flow

```text
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│   Dev   │────▶│Staging  │────▶│   QA    │────▶│  Prod   │
└─────────┘     └─────────┘     └─────────┘     └─────────┘
     │               │               │               │
     ▼               ▼               ▼               ▼
 Auto Sync       Auto Sync      Manual Sync    Manual Sync
                               + Approval     + Approval
```

### Kustomize Overlays

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base/frontend
patches:
- path: replica-patch.yaml
- path: resource-patch.yaml
images:
- name: frontend
  newTag: v1.2.3  # Production version
```

### Helm Values per Environment

```yaml
# releases/production/frontend.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    helm:
      valueFiles:
      - values.yaml
      - values-production.yaml
      parameters:
      - name: replicaCount
        value: "5"
```

---

## GitOps Workflow Examples

### Application Update Workflow

```text
1. Developer updates code
2. CI builds new image: myapp:v1.2.4
3. CI updates GitOps repo:
   - images.yaml: tag: v1.2.4
4. PR created automatically
5. Review and merge
6. ArgoCD detects change
7. ArgoCD syncs new image
8. Application updated
```

### Infrastructure Change Workflow

```text
1. Platform engineer updates infra manifests
2. Creates PR with changes
3. CI validates manifests (kubeval, kustomize build)
4. Team reviews changes
5. PR merged
6. ArgoCD applies infrastructure changes
7. Changes verified
```

### Rollback Workflow

```text
1. Issue detected in production
2. Find previous working commit
3. Git revert or update image tag
4. Commit change
5. ArgoCD syncs previous state
6. Service restored
```

---

## Tools Ecosystem

### GitOps Operators

| Tool | Maintained By | Key Features |
|------|---------------|--------------|
| **ArgoCD** | CNCF | UI, App of Apps, RBAC |
| **Flux** | CNCF | Lightweight, Helm native |
| **Rancher Fleet** | SUSE | Multi-cluster first |

### Supporting Tools

| Category | Tools |
|----------|-------|
| **Secrets** | Sealed Secrets, External Secrets, SOPS |
| **Progressive Delivery** | Argo Rollouts, Flagger |
| **Policy** | OPA Gatekeeper, Kyverno |
| **Templating** | Kustomize, Helm, jsonnet |
| **Validation** | kubeval, kubeconform, pluto |

---

## Best Practices

### Git Practices

1. **Use meaningful commit messages**
   ```
   feat(frontend): update to v1.2.3
   fix(backend): increase memory limit
   chore(infra): upgrade cert-manager
   ```

2. **Protect main/production branches**
   - Require PR reviews
   - Enforce CI checks
   - Prevent force pushes

3. **Tag releases for production**
   ```bash
   git tag -a release-2024-01-17 -m "Production release"
   ```

### Configuration Practices

1. **Environment parity** - Keep environments similar
2. **DRY (Don't Repeat Yourself)** - Use base/overlay patterns
3. **Immutable tags** - Use specific versions, not `latest`
4. **Resource limits** - Always define CPU/memory limits

### Security Practices

| Practice | Implementation |
|----------|----------------|
| Least privilege | Minimal RBAC permissions |
| Audit logging | Enable Git and cluster audit logs |
| Signed commits | Require GPG-signed commits |
| Image signing | Use cosign/notation for images |
| Policy enforcement | Use OPA/Kyverno for guardrails |

### Operational Practices

1. **Monitor sync status** - Alert on failed syncs
2. **Regular backups** - Backup etcd and Git repos
3. **Document changes** - Use PR descriptions
4. **Test in lower environments** - Promote through stages

---

## Official References

### GitOps Resources

- **OpenGitOps**: https://opengitops.dev/
- **GitOps Principles**: https://opengitops.dev/principles
- **CNCF GitOps WG**: https://github.com/cncf/tag-app-delivery/tree/main/gitops-wg

### Tools Documentation

- **ArgoCD**: https://argo-cd.readthedocs.io/
- **Flux**: https://fluxcd.io/docs/
- **Kustomize**: https://kustomize.io/
- **Helm**: https://helm.sh/docs/

### Books & Learning

- **GitOps and Kubernetes** (Manning)
- **Kubernetes Patterns** (O'Reilly)
- **The GitOps Cookbook** (O'Reilly)

---

## Quick Reference

```text
┌─────────────────────────────────────────────────────────────┐
│                  GITOPS PRINCIPLES SUMMARY                   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. DECLARATIVE        Everything as code in Git            │
│  2. VERSIONED          Git history = audit trail            │
│  3. AUTOMATED          Operator reconciles continuously     │
│  4. PULL-BASED         Cluster pulls state from Git         │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                     WORKFLOW SUMMARY                         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Deploy:  Commit ─▶ PR ─▶ Merge ─▶ Auto-sync                │
│  Rollback: Git revert ─▶ Commit ─▶ Auto-sync                │
│  Drift:   Operator detects ─▶ Auto-corrects                 │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                    REPO STRUCTURE                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  gitops-config/                                              │
│  ├── apps/           # Application manifests                 │
│  ├── infrastructure/ # Cluster components                    │
│  ├── overlays/       # Environment overrides                 │
│  └── clusters/       # Cluster-specific configs              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

*Last updated: 2026-01-17*
