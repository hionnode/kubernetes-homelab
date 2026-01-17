# ArgoCD Setup Guide

A comprehensive guide to deploying and configuring ArgoCD for GitOps-based continuous delivery on your Kubernetes cluster.

> [!TIP]
> For cluster setup prerequisites, see [talos-setup-guide.md](talos-setup-guide.md)

---

## Table of Contents

- [Overview](#overview)
- [Homelab Architecture Integration](#homelab-architecture-integration)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Initial Configuration](#initial-configuration)
- [Accessing ArgoCD](#accessing-argocd)
- [Core Concepts](#core-concepts)
- [Creating Applications](#creating-applications)
- [Syncing & Management](#syncing--management)
- [Repository Management](#repository-management)
- [RBAC & Security](#rbac--security)
- [Monitoring & Troubleshooting](#monitoring--troubleshooting)
- [Best Practices](#best-practices)
- [Official References](#official-references)

---

## Overview

### What is ArgoCD?

ArgoCD is a declarative, GitOps continuous delivery tool for Kubernetes. It follows the GitOps pattern of using Git repositories as the source of truth for defining the desired application state.

### Key Features

| Feature | Description |
|---------|-------------|
| **Declarative GitOps** | Application definitions in Git |
| **Automated Sync** | Automatic or manual sync to desired state |
| **Health Monitoring** | Real-time application health status |
| **Rollback** | Easy rollback to any Git commit |
| **Multi-Cluster** | Manage multiple clusters from one ArgoCD instance |
| **SSO Integration** | OIDC, LDAP, SAML, GitHub, GitLab, etc. |
| **RBAC** | Fine-grained access control |
| **Web UI & CLI** | User-friendly interface and CLI tools |

---

## Homelab Architecture Integration

This section covers deploying ArgoCD specifically for our Talos Kubernetes homelab cluster.

### Our Infrastructure

```text
┌─────────────────────────────────────────────────────────────────┐
│                     HOMELAB ARCHITECTURE                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   OPNsense Gateway (10.0.0.1)                                   │
│         │                                                        │
│         ▼                                                        │
│   TP-Link Managed Switch                                        │
│         │                                                        │
│   ┌─────┴─────────────────────────────────────────────────┐     │
│   │                                                        │     │
│   │   TALOS KUBERNETES CLUSTER                             │     │
│   │                                                        │     │
│   │   Control Planes:           Workers:                   │     │
│   │   ├── talos-cp-1 (10.0.0.10) VM    ├── talos-worker-1  │     │
│   │   ├── talos-cp-2 (10.0.0.11)       ├── talos-worker-2  │     │
│   │   └── talos-cp-3 (10.0.0.12)       └── talos-worker-3  │     │
│   │                                                        │     │
│   │   API VIP: 10.0.0.5:6443                               │     │
│   │   MetalLB Pool: 10.0.0.50-99                           │     │
│   │                                                        │     │
│   │   ┌────────────────────────────────────────┐           │     │
│   │   │           ARGOCD (GitOps)              │           │     │
│   │   │   Deployed on: Worker nodes            │           │     │
│   │   │   LoadBalancer IP: 10.0.0.50 (example) │           │     │
│   │   └────────────────────────────────────────┘           │     │
│   └────────────────────────────────────────────────────────┘     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why ArgoCD for This Homelab?

| Challenge | ArgoCD Solution |
|-----------|----------------|
| Managing Talos + apps declaratively | Git-based configs synced automatically |
| No SSH access to Talos nodes | Deploy everything via Kubernetes manifests |
| Reproducible cluster state | Entire cluster defined in Git |
| Easy rollbacks | Git revert = instant rollback |
| Multi-component coordination | App of Apps manages all services |

### Recommended Namespace Structure

```text
argocd/              # ArgoCD itself
infrastructure/      # Cluster components (Cilium, MetalLB, cert-manager)
monitoring/          # Prometheus, Grafana, Loki
apps/                # Your applications
```

### Homelab-Specific Configuration

```yaml
# homelab-argocd-values.yaml
server:
  service:
    type: LoadBalancer   # Gets IP from MetalLB pool (10.0.0.50-99)
    annotations:
      metallb.universe.tf/loadBalancerIPs: "10.0.0.50"  # Fixed IP

  ingress:
    enabled: false  # Use LoadBalancer directly in homelab

configs:
  params:
    server.insecure: true  # Terminate TLS at ingress/LB if needed

# Resource limits for homelab (adjust based on available resources)
controller:
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 256Mi

repoServer:
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 50m
      memory: 128Mi
```

### Accessing ArgoCD in Homelab

From any device on the `10.0.0.0/24` network:

```bash
# After installation with LoadBalancer
kubectl get svc argocd-server -n argocd
# EXTERNAL-IP will be from MetalLB pool (e.g., 10.0.0.50)

# Access UI
open https://10.0.0.50

# Or from outside homelab network via OPNsense port forward
# Configure in OPNsense: Firewall → NAT → Port Forward
```

---

## Prerequisites

Before installing ArgoCD, ensure you have:

- A running Kubernetes cluster (v1.23+)
- `kubectl` configured and connected to your cluster
- `helm` (v3+) installed for Helm-based installation (optional)
- A Git repository for storing application manifests

```bash
# Verify cluster access
kubectl cluster-info

# Verify kubectl version
kubectl version --client
```

---

## Installation

### Method 1: Standard Manifest Installation (Recommended)

```bash
# Create argocd namespace
kubectl create namespace argocd

# Install ArgoCD (stable release)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# For HA production setup
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

### Method 2: Helm Installation

```bash
# Add ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set server.service.type=LoadBalancer
```

### Verify Installation

```bash
# Check all ArgoCD pods are running
kubectl get pods -n argocd

# Expected output:
# argocd-application-controller-xxx   Running
# argocd-dex-server-xxx               Running
# argocd-redis-xxx                    Running
# argocd-repo-server-xxx              Running
# argocd-server-xxx                   Running

# Wait for all deployments to be ready
kubectl wait --for=condition=available deployment --all -n argocd --timeout=300s
```

### Install ArgoCD CLI

```bash
# macOS (Homebrew)
brew install argocd

# Linux
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

# Verify installation
argocd version --client
```

---

## Initial Configuration

### Retrieve Initial Admin Password

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

> [!WARNING]
> Change the default password immediately after first login and delete the initial secret.

### Change Admin Password

```bash
# Login to ArgoCD
argocd login <ARGOCD_SERVER>

# Update password
argocd account update-password

# Delete initial admin secret after password change
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### Configure TLS (Production)

```yaml
# argocd-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
  tls:
  - hosts:
    - argocd.example.com
    secretName: argocd-server-tls
```

---

## Accessing ArgoCD

### Port Forward (Development)

```bash
# Port forward ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access at: https://localhost:8080
```

### LoadBalancer (Production)

```bash
# Patch service type to LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Get external IP
kubectl get svc argocd-server -n argocd
```

### CLI Login

```bash
# Login via CLI
argocd login <ARGOCD_SERVER> --username admin --password <PASSWORD>

# Login with port-forward
argocd login localhost:8080 --insecure --username admin --password <PASSWORD>

# Login with SSO
argocd login <ARGOCD_SERVER> --sso
```

---

## Core Concepts

### Application

An **Application** defines the source (Git repo) and destination (Kubernetes cluster/namespace) for deployment.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/my-app.git
    targetRevision: HEAD
    path: manifests/
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### AppProject

An **AppProject** provides logical grouping and access control for applications.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production applications
  sourceRepos:
  - 'https://github.com/myorg/*'
  destinations:
  - namespace: '*'
    server: https://kubernetes.default.svc
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
```

### ApplicationSet

An **ApplicationSet** enables templating multiple applications from a single definition.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - cluster: dev
        url: https://dev.example.com
      - cluster: prod
        url: https://prod.example.com
  template:
    metadata:
      name: '{{cluster}}-app'
    spec:
      project: default
      source:
        repoURL: https://github.com/myorg/app.git
        targetRevision: HEAD
        path: 'envs/{{cluster}}'
      destination:
        server: '{{url}}'
        namespace: my-app
```

---

## Creating Applications

### Via CLI

```bash
# Create application from CLI
argocd app create my-app \
  --repo https://github.com/myorg/my-app.git \
  --path manifests/ \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace my-app \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Create from Helm chart
argocd app create my-helm-app \
  --repo https://charts.example.com \
  --helm-chart my-chart \
  --revision 1.0.0 \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace my-helm-app

# Create from Kustomize
argocd app create my-kustomize-app \
  --repo https://github.com/myorg/my-app.git \
  --path overlays/production \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace my-kustomize-app
```

### Via Manifest (Declarative)

```bash
# Apply Application manifest
kubectl apply -f application.yaml

# Example directory structure:
# argocd-apps/
# ├── applications/
# │   ├── app1.yaml
# │   ├── app2.yaml
# │   └── app3.yaml
# └── projects/
#     └── production.yaml

# Bootstrap pattern - App of Apps
kubectl apply -f app-of-apps.yaml
```

### App of Apps Pattern

```yaml
# app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/argocd-apps.git
    targetRevision: HEAD
    path: applications/
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Syncing & Management

### Sync Operations

```bash
# Sync application
argocd app sync my-app

# Sync with prune (delete removed resources)
argocd app sync my-app --prune

# Sync specific resources only
argocd app sync my-app --resource :Service:my-service

# Dry-run sync
argocd app sync my-app --dry-run

# Force sync (bypass hooks)
argocd app sync my-app --force

# Preview diff without syncing
argocd app diff my-app
```

### Application Status

```bash
# Get application details
argocd app get my-app

# List all applications
argocd app list

# Watch application status
argocd app get my-app --watch

# Get application history
argocd app history my-app
```

### Rollback

```bash
# View history
argocd app history my-app

# Rollback to previous version
argocd app rollback my-app <HISTORY_ID>

# Rollback via Git (preferred method)
# Simply revert commit in Git, ArgoCD will auto-sync
```

### Application Health

| Status | Description |
|--------|-------------|
| `Healthy` | All resources are healthy |
| `Progressing` | Resources are still being created/updated |
| `Degraded` | One or more resources are unhealthy |
| `Suspended` | Resources are suspended (e.g., CronJob) |
| `Missing` | Resources not found in cluster |
| `Unknown` | Health status cannot be determined |

---

## Repository Management

### Add Git Repository

```bash
# HTTPS with credentials
argocd repo add https://github.com/myorg/my-repo.git \
  --username git \
  --password <TOKEN>

# SSH with private key
argocd repo add git@github.com:myorg/my-repo.git \
  --ssh-private-key-path ~/.ssh/id_rsa

# GitHub App authentication
argocd repo add https://github.com/myorg/my-repo.git \
  --github-app-id <APP_ID> \
  --github-app-installation-id <INSTALL_ID> \
  --github-app-private-key-path <KEY_PATH>
```

### Add Helm Repository

```bash
# Public Helm repo
argocd repo add https://charts.example.com --type helm --name my-charts

# Private Helm repo with credentials
argocd repo add https://charts.example.com \
  --type helm \
  --name my-charts \
  --username admin \
  --password <PASSWORD>
```

### Manage Repositories

```bash
# List repositories
argocd repo list

# Remove repository
argocd repo rm https://github.com/myorg/my-repo.git
```

---

## RBAC & Security

### Project-based RBAC

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-alpha
  namespace: argocd
spec:
  description: Team Alpha applications
  sourceRepos:
  - 'https://github.com/myorg/team-alpha-*'
  destinations:
  - namespace: 'team-alpha-*'
    server: https://kubernetes.default.svc
  roles:
  - name: developer
    description: Developer access
    policies:
    - p, proj:team-alpha:developer, applications, get, team-alpha/*, allow
    - p, proj:team-alpha:developer, applications, sync, team-alpha/*, allow
    groups:
    - team-alpha-devs
```

### ConfigMap RBAC Policy

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:admin, applications, *, */*, allow
    p, role:admin, clusters, *, *, allow
    p, role:admin, repositories, *, *, allow
    p, role:admin, projects, *, *, allow
    
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, applications, action/*, */*, allow
    
    g, admin-group, role:admin
    g, dev-group, role:developer
```

### SSO Configuration (OIDC Example)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.example.com
  oidc.config: |
    name: Dex
    issuer: https://dex.example.com
    clientID: argocd
    clientSecret: $dex.oidc.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
```

---

## Monitoring & Troubleshooting

### View Logs

```bash
# ArgoCD server logs
kubectl logs -n argocd deployment/argocd-server -f

# Application controller logs
kubectl logs -n argocd deployment/argocd-application-controller -f

# Repo server logs
kubectl logs -n argocd deployment/argocd-repo-server -f

# Redis logs
kubectl logs -n argocd deployment/argocd-redis -f
```

### Debug Application Issues

```bash
# Get detailed application info
argocd app get my-app --show-operation

# View manifest diff
argocd app diff my-app

# Refresh application (re-read from Git)
argocd app get my-app --refresh

# Hard refresh (invalidate cache)
argocd app get my-app --hard-refresh
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Sync failed | Check `argocd app get <app> --show-operation` for details |
| OutOfSync but expected | Check sync status and resource excludes |
| Repository not accessible | Verify credentials and network access |
| Slow sync | Check repo-server resources, increase memory/CPU |
| Health unknown | Ensure proper health check configuration |

### Prometheus Metrics

ArgoCD exposes metrics at `/metrics` endpoint:

```yaml
# ServiceMonitor for Prometheus Operator
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  endpoints:
  - port: metrics
```

---

## Best Practices

### Repository Structure

```text
├── apps/                    # Application manifests
│   ├── base/               # Base configurations
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── overlays/           # Environment-specific
│       ├── dev/
│       ├── staging/
│       └── production/
├── argocd/                  # ArgoCD configuration
│   ├── applications/       # Application CRDs
│   ├── projects/           # AppProject CRDs
│   └── applicationsets/    # ApplicationSet CRDs
└── charts/                  # Helm charts
    └── my-app/
```

### Sync Policies

| Policy | Use Case |
|--------|----------|
| Manual sync | Production environments, requires approval |
| Auto sync | Development environments, fast iteration |
| Auto prune | Clean up removed resources automatically |
| Self-heal | Automatically correct drift from desired state |

### Security Recommendations

1. **Enable RBAC** - Use fine-grained access control
2. **Use SSO** - Integrate with identity provider
3. **Separate Projects** - Isolate teams and environments
4. **Audit Logging** - Enable and monitor audit logs
5. **Network Policies** - Restrict ArgoCD network access
6. **Secrets Management** - Use External Secrets, Sealed Secrets, or Vault

> [!IMPORTANT]
> Never store plain-text secrets in Git. Use sealed-secrets, external-secrets, or similar solutions.

### GitOps Workflow

```text
1. Developer commits to feature branch
2. CI builds and tests
3. CI creates PR to target environment branch (e.g., main)
4. PR reviewed and merged
5. ArgoCD detects change and syncs (auto or manual)
6. Application deployed to cluster
7. ArgoCD reports health status
```

---

## Official References

### Documentation

- **ArgoCD Documentation**: https://argo-cd.readthedocs.io/
- **Getting Started**: https://argo-cd.readthedocs.io/en/stable/getting_started/
- **User Guide**: https://argo-cd.readthedocs.io/en/stable/user-guide/
- **Operator Manual**: https://argo-cd.readthedocs.io/en/stable/operator-manual/

### GitHub & Community

- **GitHub Repository**: https://github.com/argoproj/argo-cd
- **Releases**: https://github.com/argoproj/argo-cd/releases
- **Slack Community**: https://argoproj.github.io/community/join-slack/
- **CNCF Project**: https://www.cncf.io/projects/argo/

### Related Tools

- **Argo Workflows**: https://argoproj.github.io/argo-workflows/
- **Argo Rollouts**: https://argoproj.github.io/argo-rollouts/
- **Argo Events**: https://argoproj.github.io/argo-events/
- **Sealed Secrets**: https://sealed-secrets.netlify.app/
- **External Secrets**: https://external-secrets.io/

---

## Quick Reference Card

```text
┌─────────────────────────────────────────────────────────────┐
│                   ARGOCD QUICK REFERENCE                     │
├─────────────────────────────────────────────────────────────┤
│ LOGIN & AUTH                                                 │
│   argocd login <SERVER>        # Login to ArgoCD            │
│   argocd account list          # List accounts              │
│   argocd account update-password  # Change password         │
├─────────────────────────────────────────────────────────────┤
│ APPLICATIONS                                                 │
│   argocd app list              # List all applications      │
│   argocd app create            # Create application         │
│   argocd app get <APP>         # Get application details    │
│   argocd app sync <APP>        # Sync application           │
│   argocd app delete <APP>      # Delete application         │
├─────────────────────────────────────────────────────────────┤
│ SYNC & DIFF                                                  │
│   argocd app sync <APP>        # Sync to desired state      │
│   argocd app sync <APP> --prune  # Sync with prune          │
│   argocd app diff <APP>        # Show diff                  │
│   argocd app rollback <APP> <ID>  # Rollback to revision    │
├─────────────────────────────────────────────────────────────┤
│ REPOSITORIES                                                 │
│   argocd repo list             # List repositories          │
│   argocd repo add <URL>        # Add repository             │
│   argocd repo rm <URL>         # Remove repository          │
├─────────────────────────────────────────────────────────────┤
│ PROJECTS                                                     │
│   argocd proj list             # List projects              │
│   argocd proj create           # Create project             │
│   argocd proj get <PROJ>       # Get project details        │
├─────────────────────────────────────────────────────────────┤
│ CLUSTERS                                                     │
│   argocd cluster list          # List clusters              │
│   argocd cluster add           # Add cluster                │
└─────────────────────────────────────────────────────────────┘
```

---

*Last updated: 2026-01-17*
