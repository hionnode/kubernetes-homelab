# Kubernetes Homelab Observability Guide

Two-plane observability strategy: **Grafana Cloud** for infrastructure monitoring that survives cluster failures, and an **in-cluster LGTM stack** (or SigNoz) for deep application telemetry without egress costs.

> [!TIP]
> **Cross-references**: [architecture-diagrams.md](architecture-diagrams.md) for network topology, [argocd-setup-guide.md](argocd-setup-guide.md) for GitOps deployment patterns, [talos-management-handbook.md](talos-management-handbook.md) for Talos operations.

---

## Table of Contents

- [1. Observability Philosophy](#1-observability-philosophy)
- [2. Platform Observability (Grafana Cloud)](#2-platform-observability-grafana-cloud)
- [3. Application Observability (In-Cluster)](#3-application-observability-in-cluster)
- [4. Operations Runbook](#4-operations-runbook)
- [5. Further Reading](#5-further-reading)

---

## 1. Observability Philosophy

### 1.1 Why Two Planes?

A single observability stack inside the cluster creates a circular dependency: when the cluster fails, you lose visibility into why it failed. Separating infrastructure monitoring from application monitoring eliminates this blind spot.

| Failure Scenario | Single-Plane Impact | Two-Plane Impact |
|------------------|---------------------|------------------|
| Cluster network partition | **Blind** — no metrics, no logs, no alerting | Grafana Cloud still receives Proxmox/OPNsense metrics; alerts fire |
| etcd quorum loss | **Blind** — Prometheus pods cannot schedule | Grafana Cloud shows etcd leader loss; in-cluster stack down but acceptable (app data only) |
| Worker node OOM | In-cluster stack may be on affected node | Grafana Cloud unaffected; in-cluster Grafana recovers after reschedule |
| OPNsense gateway failure | In-cluster stack cannot egress to anything | Grafana Cloud has last-known state; Proxmox Alloy continues local scrape |
| Proxmox host failure | CP1 VM and OPNsense VM both down | Grafana Cloud alerts on missing Proxmox host; physical CPs maintain partial cluster |

**Cost/control trade-off**: Grafana Cloud free tier handles infrastructure metrics cheaply (low cardinality). Application telemetry generates orders of magnitude more data — keeping it in-cluster avoids egress costs and gives full retention control.

### 1.2 Choosing Grafana Alloy

Grafana Alloy is the successor to both Grafana Agent and Promtail. It provides a single binary for collecting metrics, logs, and traces — fewer moving parts, fewer failure modes, one config language.

**River config language primer**:

```hcl
// River uses blocks and attributes — similar to HCL but purpose-built for Alloy.
// Components are connected by wiring outputs to inputs.

prometheus.scrape "example" {
  targets    = [{"__address__" = "localhost:9090"}]
  forward_to = [prometheus.remote_write.cloud.receiver]  // wires output → input
}

prometheus.remote_write "cloud" {
  endpoint {
    url = "https://prometheus-prod-xx-xxx.grafana.net/api/prom/push"
    basic_auth {
      username = env("GRAFANA_CLOUD_USER")
      password = env("GRAFANA_CLOUD_TOKEN")
    }
  }
}
```

Key concepts:
- **Components** (`prometheus.scrape`, `loki.source.kubernetes`, etc.) are the building blocks
- **Labels** (`"example"`, `"cloud"`) distinguish multiple instances of the same component type
- **Wiring** connects components via `.receiver` / `.output` exports
- **`env()`** reads environment variables — never hardcode secrets in River configs

### 1.3 Talos-Specific Constraints

Talos Linux is an immutable, API-driven OS. This constrains how we collect telemetry:

| Constraint | Impact on Observability |
|------------|------------------------|
| No SSH, no shell access | Cannot install exporters on nodes directly; must use DaemonSets or built-in endpoints |
| No `apt`/`yum` | node_exporter cannot run as a host package; Talos exposes equivalent metrics via `machined` |
| Kubelet metrics at `:10250` | Requires HTTPS + service account token; `insecure_skip_verify` needed for self-signed certs |
| etcd metrics at `:2381` | Only accessible from control plane nodes; DaemonSet needs `hostNetwork: true` |
| Log paths differ | Container logs at `/var/log/pods/`, not the standard `/var/log/containers/` symlinks on some setups |
| DaemonSet requirements | `hostNetwork: true`, tolerations for control-plane taints, projected service account tokens |

### 1.4 Secrets Strategy

All observability credentials (Grafana Cloud tokens, API keys) follow the same pattern:

1. **Kubernetes Secrets** store the values in-cluster
2. **ArgoCD** syncs the Secret manifests from Git (encrypted with sealed-secrets or managed by external-secrets)
3. **Alloy** reads secrets via `env()` from environment variables injected by the Secret

```yaml
# Example: Secret for Grafana Cloud credentials
apiVersion: v1
kind: Secret
metadata:
  name: grafana-cloud-credentials
  namespace: monitoring
type: Opaque
stringData:
  username: "<instance-id>"
  token: "<api-key>"
```

> [!IMPORTANT]
> Never commit plaintext secrets to Git. Use [sealed-secrets](https://sealed-secrets.netlify.app/) or [external-secrets](https://external-secrets.io/) with ArgoCD to manage encrypted secret manifests. See [argocd-setup-guide.md](argocd-setup-guide.md) for the GitOps workflow.

---

## 2. Platform Observability (Grafana Cloud)

### 2.1 Architecture

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                              GRAFANA CLOUD                                    │
│                       (Infrastructure Monitoring)                             │
│   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                       │
│   │   Grafana    │   │    Mimir    │   │    Loki     │                       │
│   │  Dashboards  │   │   Metrics   │   │    Logs     │                       │
│   └─────────────┘   └──────▲──────┘   └──────▲──────┘                       │
└────────────────────────────┼────────────────┼────────────────────────────────┘
                             │                │
              ┌──────────────┴────────────────┴──────────────┐
              │         remote_write / loki.write             │
              └──────────────┬────────────────┬──────────────┘
                             │                │
         ┌───────────────────┼────────────────┼───────────────────┐
         │                   │                │                   │
    ┌────┴──────┐   ┌───────┴───────┐   ┌────┴──────┐   ┌───────┴────────┐
    │  Alloy    │   │ Alloy DaemonSet│   │  (same    │   │  (same Alloy   │
    │ (Proxmox  │   │  (in-cluster) │   │  Alloy    │   │   on Proxmox   │
    │   host)   │   │               │   │  scrapes  │   │   scrapes      │
    │           │   │ kubelet:10250 │   │  OPNsense)│   │   node_exporter│
    │ pve-exp.  │   │ etcd:2381    │   │  :9100    │   │   :9100)       │
    └───────────┘   └───────────────┘   └───────────┘   └────────────────┘
         │                   │                │                   │
    ┌────┴──────┐   ┌───────┴───────┐   ┌────┴──────┐   ┌───────┴────────┐
    │  Proxmox  │   │  Talos Nodes  │   │ OPNsense  │   │   Proxmox      │
    │   Host    │   │ 10.0.0.10-12  │   │  10.0.0.1 │   │     Host       │
    │192.168.   │   │ 10.0.0.20-22  │   │           │   │  192.168.1.110 │
    │  1.110    │   │               │   │           │   │                │
    └───────────┘   └───────────────┘   └───────────┘   └────────────────┘
```

### 2.2 Grafana Cloud Account Setup

**SRE rationale**: An external monitoring plane survives every failure mode inside your LAN. Grafana Cloud free tier is sufficient for infrastructure metrics from a homelab-scale deployment.

#### Stack Creation

1. Sign up at [grafana.com/cloud](https://grafana.com/cloud)
2. Create a new stack (e.g., `homelab-infra`)
3. Navigate to **Administration → Cloud Access Policies**
4. Create a policy with scopes: `metrics:write`, `logs:write`, `traces:write`
5. Generate a token and store it securely

#### Endpoint Reference

| Component | Endpoint Pattern | Purpose |
|-----------|-----------------|---------|
| Grafana UI | `https://<stack>.grafana.net` | Dashboards, alerting |
| Prometheus (Mimir) | `https://prometheus-<region>.grafana.net/api/prom/push` | `remote_write` target |
| Loki | `https://logs-<region>.grafana.net/loki/api/v1/push` | Log push target |
| Tempo | `https://tempo-<region>.grafana.net/tempo` | Trace push target |
| Instance ID | Found in stack details | Used as `username` for basic auth |

> [!WARNING]
> **Free tier limits**: 10,000 active metric series, 50 GB logs/month, 50 GB traces/month, 14-day retention, 3 users. Exceeding the series limit silently drops new series. Use relabeling rules aggressively to control cardinality (see [Section 2.5](#25-talos-node-metrics)).

### 2.3 Proxmox Host Monitoring

**SRE rationale**: The Proxmox host runs the CP1 VM and the OPNsense VM. If it goes down, you lose your only virtualized control plane node and your network gateway. You must know about Proxmox problems before they cascade.

#### Install pve-exporter

On the Proxmox host:

```bash
# Install pve-exporter
apt update && apt install python3-pip -y
pip3 install prometheus-pve-exporter

# Create config
cat > /etc/pve-exporter.yml << 'EOF'
default:
  user: root@pam
  token_name: prometheus
  token_value: <your-api-token>
  verify_ssl: false
EOF

# Create systemd service
cat > /etc/systemd/system/pve-exporter.service << 'EOF'
[Unit]
Description=Proxmox VE Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/pve_exporter /etc/pve-exporter.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pve-exporter
# Verify: curl -s localhost:9221/pve?target=localhost | head
```

#### Install Alloy on Proxmox

```bash
# Add Grafana repository
apt-get install -y gpg
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/grafana.gpg
echo "deb https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list

apt update && apt install alloy -y
```

Configure `/etc/alloy/config.alloy`:

```hcl
// --- Proxmox host metrics ---
prometheus.scrape "proxmox" {
  targets    = [{"__address__" = "localhost:9221"}]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  scrape_interval = "60s"
}

prometheus.scrape "node" {
  targets    = [{"__address__" = "localhost:9100"}]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  scrape_interval = "60s"
}

// --- OPNsense metrics (scraped from Proxmox since it has LAN access) ---
prometheus.scrape "opnsense" {
  targets    = [{"__address__" = "10.0.0.1:9100"}]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  scrape_interval = "30s"
}

// --- Ship to Grafana Cloud ---
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = env("GRAFANA_CLOUD_PROM_URL")
    basic_auth {
      username = env("GRAFANA_CLOUD_USER")
      password = env("GRAFANA_CLOUD_TOKEN")
    }
  }
  external_labels = {
    env     = "homelab",
    plane   = "infrastructure",
    host    = "proxmox",
  }
}
```

Set credentials in `/etc/default/alloy`:

```bash
GRAFANA_CLOUD_PROM_URL="https://prometheus-prod-xx-xxx.grafana.net/api/prom/push"
GRAFANA_CLOUD_USER="<instance-id>"
GRAFANA_CLOUD_TOKEN="<api-key>"
```

```bash
systemctl enable --now alloy
# Verify: journalctl -u alloy -f
```

### 2.4 OPNsense Monitoring

**SRE rationale**: OPNsense is a single point of failure — the only gateway between your Kubernetes network (10.0.0.0/24) and the outside world. If it fails, pods cannot reach external services, and you cannot reach the cluster from outside the LAN. Monitoring latency, CPU, and interface errors gives early warning before full outage.

#### Enable Prometheus Exporter

1. **System → Firmware → Plugins** → install `os-prometheus-exporter`
2. **Services → Prometheus Exporter** → configure:

| Setting | Value |
|---------|-------|
| Enable | Checked |
| Listen Address | `10.0.0.1` (LAN only — never expose on WAN) |
| Listen Port | `9100` |

3. The Proxmox Alloy config from [Section 2.3](#23-proxmox-host-monitoring) already includes the OPNsense scrape target at `10.0.0.1:9100`.

#### Key Metrics to Watch

| Metric | Why It Matters |
|--------|---------------|
| `node_network_receive_errs_total` | Interface errors precede link failure |
| `node_cpu_seconds_total` | OPNsense does packet inspection in software; CPU saturation = packet drops |
| `node_network_transmit_bytes_total` | Egress spike may indicate exfiltration or misconfigured workload |
| `up{job="opnsense"}` | Gateway reachability — most critical check |

### 2.5 Talos Node Metrics

Talos exposes metrics through built-in endpoints — no node_exporter needed:

| Endpoint | Port | Protocol | What It Exposes |
|----------|------|----------|-----------------|
| Kubelet | `:10250` | HTTPS | Node resource usage, pod stats, container metrics |
| etcd | `:2381` | HTTP | Cluster health, leader status, proposal counts |
| Talos `machined` | `:9100` | HTTP | Node-level hardware metrics (Talos built-in) |
| kube-proxy | `:10249` | HTTP | Network rule sync metrics (if not using Cilium replacement) |

#### Alloy DaemonSet Manifest

This DaemonSet runs on every node, scrapes local endpoints, and forwards to Grafana Cloud.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alloy-infra
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alloy-infra
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/metrics", "nodes/proxy"]
    verbs: ["get", "list"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alloy-infra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: alloy-infra
subjects:
  - kind: ServiceAccount
    name: alloy-infra
    namespace: monitoring
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-cloud-credentials
  namespace: monitoring
type: Opaque
stringData:
  username: "<instance-id>"
  token: "<api-key>"
  prom_url: "https://prometheus-prod-xx-xxx.grafana.net/api/prom/push"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-infra-config
  namespace: monitoring
data:
  config.alloy: |
    // --- Kubelet metrics (every node) ---
    prometheus.scrape "kubelet" {
      targets = [{"__address__" = "localhost:10250"}]
      scheme  = "https"
      tls_config {
        insecure_skip_verify = true
      }
      bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      forward_to = [prometheus.relabel.cardinality.receiver]
      scrape_interval = "60s"
    }

    // --- etcd metrics (control plane nodes only, fails silently on workers) ---
    prometheus.scrape "etcd" {
      targets = [{"__address__" = "localhost:2381"}]
      forward_to = [prometheus.relabel.cardinality.receiver]
      scrape_interval = "60s"
    }

    // --- Cardinality control (critical for free tier) ---
    prometheus.relabel "cardinality" {
      rule {
        action        = "drop"
        source_labels = ["__name__"]
        regex         = "(etcd_debugging_|etcd_disk_defrag_|apiserver_admission_).*"
      }
      rule {
        action        = "drop"
        source_labels = ["__name__"]
        regex         = "kubelet_runtime_operations_duration_seconds_bucket"
      }
      forward_to = [prometheus.remote_write.grafana_cloud.receiver]
    }

    // --- Ship to Grafana Cloud ---
    prometheus.remote_write "grafana_cloud" {
      endpoint {
        url = env("GRAFANA_CLOUD_PROM_URL")
        basic_auth {
          username = env("GRAFANA_CLOUD_USER")
          password = env("GRAFANA_CLOUD_TOKEN")
        }
      }
      external_labels = {
        cluster = "homelab",
        plane   = "infrastructure",
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: alloy-infra
  namespace: monitoring
  labels:
    app: alloy-infra
spec:
  selector:
    matchLabels:
      app: alloy-infra
  template:
    metadata:
      labels:
        app: alloy-infra
    spec:
      serviceAccountName: alloy-infra
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      tolerations:
        - operator: Exists    # Run on control plane nodes too
      containers:
        - name: alloy
          image: grafana/alloy:v1.5.1
          args:
            - run
            - /etc/alloy/config.alloy
            - --server.http.listen-addr=0.0.0.0:12345
          ports:
            - name: http
              containerPort: 12345
              protocol: TCP
          env:
            - name: GRAFANA_CLOUD_PROM_URL
              valueFrom:
                secretKeyRef:
                  name: grafana-cloud-credentials
                  key: prom_url
            - name: GRAFANA_CLOUD_USER
              valueFrom:
                secretKeyRef:
                  name: grafana-cloud-credentials
                  key: username
            - name: GRAFANA_CLOUD_TOKEN
              valueFrom:
                secretKeyRef:
                  name: grafana-cloud-credentials
                  key: token
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: alloy-infra-config
```

### 2.6 Infrastructure Dashboards

Import these dashboards in Grafana Cloud (**Dashboards → Import → paste ID**):

| Dashboard ID | Name | Monitors |
|--------------|------|----------|
| `10347` | Proxmox VE | Host CPU, RAM, VM status, storage |
| `1860` | Node Exporter Full | Proxmox host hardware (disk, network, CPU) |
| `12644` | OPNsense | Firewall throughput, interface errors, CPU |
| `6417` | Kubernetes Pods | Basic pod resource view |

#### Custom "Homelab Overview" Panel Suggestions

Build a single overview dashboard with these panels:

| Panel | PromQL | Purpose |
|-------|--------|---------|
| Cluster Node Status | `count(kube_node_status_condition{condition="Ready",status="true"})` | At-a-glance node count |
| etcd Leader | `etcd_server_has_leader` | 1 = healthy, 0 = page |
| OPNsense Up | `up{job="opnsense"}` | Gateway reachability |
| Proxmox CPU | `100 - (avg(rate(node_cpu_seconds_total{mode="idle",instance=~".*proxmox.*"}[5m])) * 100)` | Hypervisor load |
| Disk Space (all) | `1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})` | Per-host disk usage |

### 2.7 Infrastructure Alerts

#### Alert Design Principles

- **Page on symptoms, not causes**: "Node NotReady" (symptom) is actionable; "CPU at 80%" (cause) is not — it may be fine under load
- **Include a runbook link**: Every alert should point to a troubleshooting section
- **Escalate in tiers**: Warning (Slack) → Critical (phone/PagerDuty)

#### Alerts Table

| Alert Name | PromQL | Severity | For | Runbook |
|------------|--------|----------|-----|---------|
| Proxmox Host Down | `up{job="proxmox"} == 0` | Critical | 2m | [4.2 Troubleshooting](#42-troubleshooting-table) |
| Talos Node NotReady | `kube_node_status_condition{condition="Ready",status="true"} == 0` | Critical | 5m | [4.2 Troubleshooting](#42-troubleshooting-table) |
| etcd Leader Lost | `etcd_server_has_leader == 0` | Critical | 1m | [talos-management-handbook.md — etcd Operations](talos-management-handbook.md#etcd-operations) |
| OPNsense Unreachable | `up{job="opnsense"} == 0` | Critical | 2m | [4.2 Troubleshooting](#42-troubleshooting-table) |
| Disk Space < 15% | `(node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.15` | Warning | 10m | Expand storage or clean up |
| High Memory Usage | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9` | Warning | 10m | Check for memory leaks |
| Certificate Expiring | `probe_ssl_earliest_cert_expiry - time() < 86400 * 14` | Warning | 1h | Renew certificates |
| etcd DB Size Large | `etcd_mvcc_db_total_size_in_bytes > 6e+09` | Warning | 5m | Run etcd defrag |

#### Contact Points Setup

Configure in Grafana Cloud under **Alerting → Contact points**:

| Channel | Setup |
|---------|-------|
| Slack | Create incoming webhook → paste URL in contact point config |
| Discord | Server Settings → Integrations → Webhooks → use `/slack` suffix on the webhook URL |
| Email | Built-in — add recipient addresses directly |

### 2.8 ArgoCD Deployment

Deploy the Alloy infrastructure DaemonSet via ArgoCD for GitOps management.

#### Directory Structure

```
gitops-repo/
└── infrastructure/
    └── monitoring/
        ├── namespace.yaml
        ├── alloy-infra/
        │   ├── rbac.yaml
        │   ├── configmap.yaml
        │   ├── secret.yaml          # SealedSecret in practice
        │   └── daemonset.yaml
        └── kustomization.yaml       # optional, if using Kustomize
```

#### ArgoCD Application Manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-infra
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/<gitops-repo>.git
    targetRevision: HEAD
    path: infrastructure/monitoring/alloy-infra
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 3. Application Observability (In-Cluster)

### 3.1 Architecture

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                           KUBERNETES CLUSTER                                  │
│                     (Application Observability)                               │
│                                                                               │
│   ┌───────────────────────────────────────────────────────────────────────┐   │
│   │                     Observability Namespace                           │   │
│   │                                                                       │   │
│   │  ┌───────────┐  ┌────────────┐  ┌───────────┐  ┌───────────────┐    │   │
│   │  │  Grafana  │  │ Prometheus │  │   Loki    │  │    Tempo      │    │   │
│   │  │    UI     │  │  (Mimir)   │  │   Logs    │  │   Traces      │    │   │
│   │  │ :3000     │  │  :9090     │  │  :3100    │  │ :4317/:4318   │    │   │
│   │  └───────────┘  └─────▲──────┘  └─────▲─────┘  └──────▲────────┘    │   │
│   │                       │               │                │             │   │
│   │           ┌───────────┴───────────────┴────────────────┴──────┐      │   │
│   │           │              Alloy (Collector)                     │      │   │
│   │           │   DaemonSet: log collection from /var/log/pods     │      │   │
│   │           │   Deployment: OTLP receiver for traces             │      │   │
│   │           └───────────────────────▲───────────────────────────┘      │   │
│   └───────────────────────────────────┼──────────────────────────────────┘   │
│                                       │                                      │
│               ┌───────────────────────┴────────────────────────┐             │
│               │                Applications                     │             │
│               │   metrics → /metrics (Prometheus scrape)        │             │
│               │   logs    → stdout/stderr (Alloy collects)      │             │
│               │   traces  → OTLP (Alloy receives)               │             │
│               └─────────────────────────────────────────────────┘             │
└───────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 SRE Rationale

The in-cluster plane gives you full-depth application telemetry — distributed traces, structured logs, high-cardinality metrics — without paying per-GB egress to a cloud provider. The trade-off is explicit: this stack goes down with the cluster, but that is acceptable because it only monitors application-level data. Infrastructure monitoring (the stuff you need during cluster failures) lives in Grafana Cloud.

### 3.3 Option A: Grafana LGTM Stack (Primary)

The LGTM stack (Loki, Grafana, Tempo, Mimir/Prometheus) gives you full control with industry-standard tooling.

#### 3.3.1 Helm Deployment

```bash
# Add Helm repos
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

**Loki (logs)**:

```bash
helm install loki grafana/loki \
  --namespace observability \
  --create-namespace \
  --set loki.auth_enabled=false \
  --set singleBinary.replicas=1 \
  --set loki.storage.type=filesystem \
  --set singleBinary.persistence.size=10Gi \
  --set loki.limits_config.retention_period=168h       # 7-day retention
```

**Tempo (traces)**:

```bash
helm install tempo grafana/tempo \
  --namespace observability \
  --set tempo.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317" \
  --set tempo.receivers.otlp.protocols.http.endpoint="0.0.0.0:4318" \
  --set persistence.enabled=true \
  --set persistence.size=10Gi
```

**kube-prometheus-stack (metrics)**:

```bash
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --set grafana.enabled=false \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi
```

> [!TIP]
> Disabling Grafana in kube-prometheus-stack avoids a duplicate Grafana instance — we deploy our own with persistence and data source provisioning below.

**Grafana (UI)**:

```bash
helm install grafana grafana/grafana \
  --namespace observability \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set adminPassword=admin \
  --set service.type=LoadBalancer \
  --set service.loadBalancerIP=10.0.0.51
```

This assigns a MetalLB IP from the pool (10.0.0.50-99). Access at `http://10.0.0.51:3000`.

#### Data Source Provisioning

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: observability
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://kube-prometheus-kube-prome-prometheus:9090
        isDefault: true
      - name: Loki
        type: loki
        url: http://loki:3100
      - name: Tempo
        type: tempo
        url: http://tempo:3100
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
            filterByTraceID: true
          tracesToMetrics:
            datasourceUid: prometheus
```

#### 3.3.2 Alloy as Unified Collector

Alloy replaces Promtail for log collection and acts as the OTLP receiver for traces — one agent, two roles.

**DaemonSet for log collection**:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-app-config
  namespace: observability
data:
  config.alloy: |
    // --- Kubernetes log discovery ---
    loki.source.kubernetes "pods" {
      targets    = discovery.kubernetes.pods.targets
      forward_to = [loki.write.local.receiver]
    }

    discovery.kubernetes "pods" {
      role = "pod"
    }

    loki.write "local" {
      endpoint {
        url = "http://loki:3100/loki/api/v1/push"
      }
    }

    // --- OTLP receiver for application traces ---
    otelcol.receiver.otlp "default" {
      grpc {
        endpoint = "0.0.0.0:4317"
      }
      http {
        endpoint = "0.0.0.0:4318"
      }
      output {
        traces = [otelcol.exporter.otlp.tempo.input]
      }
    }

    otelcol.exporter.otlp "tempo" {
      client {
        endpoint = "tempo.observability.svc:4317"
        tls {
          insecure = true
        }
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: alloy-app
  namespace: observability
  labels:
    app: alloy-app
spec:
  selector:
    matchLabels:
      app: alloy-app
  template:
    metadata:
      labels:
        app: alloy-app
    spec:
      serviceAccountName: alloy-app
      containers:
        - name: alloy
          image: grafana/alloy:v1.5.1
          args:
            - run
            - /etc/alloy/config.alloy
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: alloy-app-config
        - name: varlogpods
          hostPath:
            path: /var/log/pods
```

> [!WARNING]
> **Talos log path caveat**: Talos writes container logs to `/var/log/pods/<namespace>_<pod>_<uid>/<container>/`. The standard `/var/log/containers/` symlinks may not exist on all Talos versions. Always mount `/var/log/pods` directly.

### 3.4 Option B: SigNoz (Alternative)

SigNoz is an all-in-one observability platform backed by ClickHouse. It provides metrics, logs, and traces in a single UI with built-in APM dashboards.

#### Helm Install

```bash
helm repo add signoz https://charts.signoz.io
helm repo update

helm install signoz signoz/signoz \
  --namespace observability \
  --create-namespace \
  --set global.storageClass=<your-storage-class> \
  --set clickhouse.persistence.size=20Gi \
  --set frontend.service.type=LoadBalancer
```

Access the UI:

```bash
# If using LoadBalancer
kubectl -n observability get svc signoz-frontend

# Or port-forward
kubectl -n observability port-forward svc/signoz-frontend 3301:3301
# Open: http://localhost:3301
```

#### When to Choose SigNoz vs LGTM

| Factor | LGTM Stack | SigNoz |
|--------|-----------|--------|
| **Setup complexity** | Multiple Helm releases, more config | Single Helm release |
| **UI** | Grafana (highly customizable, steep learning curve) | Purpose-built APM UI (simpler, opinionated) |
| **Storage backend** | Per-signal (Prometheus TSDB, filesystem, etc.) | ClickHouse (unified, efficient compression) |
| **OpenTelemetry support** | Via Alloy/Collector | Native (OTLP-first design) |
| **Community/ecosystem** | Massive — dashboards, exporters, integrations | Growing — fewer pre-built integrations |
| **Resource footprint** | Higher (4+ separate components) | Lower (ClickHouse + query service + frontend) |
| **Trace-to-log correlation** | Manual config between Tempo/Loki | Built-in |
| **Best for** | Teams who want maximum flexibility | Teams who want fast time-to-value |

### 3.5 Instrumenting Applications

#### OTLP Environment Variables

Both LGTM and SigNoz accept OTLP. Configure your application pods with:

For **LGTM stack** (via Alloy):

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://alloy-app.observability.svc:4317"
  - name: OTEL_SERVICE_NAME
    value: "myapp"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=homelab"
```

For **SigNoz**:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.observability.svc:4317"
  - name: OTEL_SERVICE_NAME
    value: "myapp"
```

#### ServiceMonitor CRD

For applications that expose a `/metrics` endpoint:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp-metrics
  namespace: observability
  labels:
    release: kube-prometheus    # must match Prometheus operator selector
spec:
  selector:
    matchLabels:
      app: myapp
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
  namespaceSelector:
    any: true
```

#### Auto-Instrumentation Examples

**Python**:

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install    # auto-detect frameworks
opentelemetry-instrument python app.py
```

**Go**:

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer() (*trace.TracerProvider, error) {
    exporter, err := otlptracegrpc.New(context.Background())
    if err != nil {
        return nil, err
    }
    tp := trace.NewTracerProvider(trace.WithBatcher(exporter))
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

### 3.6 Log Collection with Alloy

The Alloy DaemonSet from [Section 3.3.2](#332-alloy-as-unified-collector) handles log collection. Key configuration details:

#### Useful LogQL Queries

```logql
# All errors from a specific namespace
{namespace="production"} |= "error"

# Parse JSON logs and filter by level
{namespace="production"} | json | level="error"

# Count errors per service over 5 minutes
sum by (app) (count_over_time({namespace="production"} |= "error" [5m]))

# Find slow requests (parse duration from JSON logs)
{namespace="production"} | json | duration > 1s

# Tail logs for a specific pod
{pod=~"myapp-.*"} | json

# Errors correlated with a trace ID
{namespace="production"} |= "trace_id" | json | trace_id="abc123"
```

### 3.7 Application Dashboards

#### RED Method Template

Every service should have a dashboard showing Rate, Errors, and Duration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: red-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  red-template.json: |
    {
      "title": "Service RED Metrics",
      "templating": {
        "list": [
          {
            "name": "namespace",
            "type": "query",
            "query": "label_values(http_requests_total, namespace)"
          },
          {
            "name": "service",
            "type": "query",
            "query": "label_values(http_requests_total{namespace=\"$namespace\"}, service)"
          }
        ]
      },
      "panels": [
        {
          "title": "Request Rate",
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{namespace=\"$namespace\",service=\"$service\"}[5m])) by (method, status_code)"
            }
          ]
        },
        {
          "title": "Error Rate (%)",
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{namespace=\"$namespace\",service=\"$service\",status_code=~\"5..\"}[5m])) / sum(rate(http_requests_total{namespace=\"$namespace\",service=\"$service\"}[5m])) * 100"
            }
          ]
        },
        {
          "title": "P99 Latency",
          "targets": [
            {
              "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$namespace\",service=\"$service\"}[5m])) by (le))"
            }
          ]
        }
      ]
    }
```

Deploy dashboards as ConfigMaps with the `grafana_dashboard: "1"` label — the Grafana sidecar auto-discovers them.

### 3.8 Application Alerts & SLOs

#### SLI/SLO Framework

Define Service Level Indicators (SLIs) and Objectives (SLOs) for each critical service:

| SLI | Measurement | SLO Target |
|-----|-------------|------------|
| Availability | `1 - (rate(http_requests_total{status_code=~"5.."}[30d]) / rate(http_requests_total[30d]))` | 99.5% (3.6h downtime/month) |
| Latency (P99) | `histogram_quantile(0.99, ...)` | < 500ms |
| Error rate | `rate(http_requests_total{status_code=~"5.."}[5m]) / rate(http_requests_total[5m])` | < 0.5% |

#### Error Budget Concept

With a 99.5% availability SLO over 30 days, your error budget is 0.5% = ~3.6 hours of downtime. When error budget is consumed:
- Freeze feature releases
- Focus engineering on reliability
- Only ship fixes that improve SLO

#### PrometheusRule CRD Examples

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: app-alerts
  namespace: observability
  labels:
    release: kube-prometheus
spec:
  groups:
    - name: application.rules
      rules:
        - alert: PodCrashLooping
          expr: |
            kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping"
            runbook: "Check logs: kubectl logs -n {{ $labels.namespace }} {{ $labels.pod }} --previous"

        - alert: HighErrorRate
          expr: |
            sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (namespace, service)
            / sum(rate(http_requests_total[5m])) by (namespace, service)
            > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Service {{ $labels.service }} error rate above 5%"

        - alert: P99LatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket[5m])) by (le, namespace, service)
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Service {{ $labels.service }} P99 latency above 1s"

        - alert: PVCAlmostFull
          expr: |
            kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "PVC {{ $labels.persistentvolumeclaim }} is >90% full"

    - name: slo.rules
      rules:
        # 30-day error budget burn rate (fast burn = alert quickly)
        - alert: SLOBurnRateFast
          expr: |
            (
              sum(rate(http_requests_total{status_code=~"5.."}[1h])) by (service)
              / sum(rate(http_requests_total[1h])) by (service)
            ) > (14.4 * 0.005)
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Service {{ $labels.service }} burning error budget 14.4x faster than allowed"

        - alert: SLOBurnRateSlow
          expr: |
            (
              sum(rate(http_requests_total{status_code=~"5.."}[6h])) by (service)
              / sum(rate(http_requests_total[6h])) by (service)
            ) > (6 * 0.005)
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Service {{ $labels.service }} burning error budget 6x faster than allowed"
```

### 3.9 ArgoCD Deployment

Use the app-of-apps pattern to manage the entire observability namespace.

#### Directory Structure

```
gitops-repo/
└── observability/
    ├── app-of-apps.yaml              # Root ArgoCD Application
    ├── loki/
    │   └── values.yaml
    ├── tempo/
    │   └── values.yaml
    ├── kube-prometheus-stack/
    │   └── values.yaml
    ├── grafana/
    │   ├── values.yaml
    │   └── dashboards/
    │       └── red-template.json
    ├── alloy-app/
    │   ├── configmap.yaml
    │   ├── daemonset.yaml
    │   └── rbac.yaml
    └── alerts/
        └── prometheusrule.yaml
```

#### App-of-Apps Manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/<gitops-repo>.git
    targetRevision: HEAD
    path: observability
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 4. Operations Runbook

### 4.1 Day-2 Operations

#### Scaling Path

| Component | Single-Binary (Current) | Microservices (Scale-Up) |
|-----------|------------------------|--------------------------|
| Loki | `singleBinary.replicas=1` | Switch to `loki-distributed` chart with separate read/write/backend |
| Tempo | Single binary | Switch to `tempo-distributed` with ingesters + compactors |
| Prometheus | Single instance | Add Thanos sidecar for long-term storage + HA |
| Alloy | DaemonSet | No change needed — DaemonSet scales with nodes |

**When to scale**: When you see query timeouts, ingestion lag (check `loki_ingester_wal_records_logged_total` falling behind), or Prometheus memory >80% of its limit.

#### Upgrading Components

```bash
# Update Helm repos
helm repo update

# Check for available updates
helm list -n observability

# Upgrade individual components (Loki example)
helm upgrade loki grafana/loki \
  --namespace observability \
  --reuse-values \
  --version <new-version>

# Verify after upgrade
kubectl -n observability rollout status deployment/loki
```

#### Rotating Credentials

1. Generate new token in Grafana Cloud
2. Update the Kubernetes Secret (or SealedSecret source)
3. Restart Alloy pods to pick up new credentials:
   ```bash
   kubectl -n monitoring rollout restart daemonset/alloy-infra
   ```

### 4.2 Troubleshooting Table

| Symptom | Diagnostic Command | Likely Fix |
|---------|--------------------| -----------|
| No metrics in Grafana Cloud | `kubectl -n monitoring logs -l app=alloy-infra --tail=50` | Check credentials in Secret; verify Alloy can reach Grafana Cloud endpoints |
| Missing in-cluster logs | `kubectl -n observability logs -l app=alloy-app --tail=50` | Verify `/var/log/pods` is mounted; check Loki is accepting pushes |
| High cardinality warning | `curl -s localhost:12345/metrics \| grep alloy_component_.*active_series` | Add relabeling rules to drop high-cardinality labels |
| Traces not appearing | `kubectl -n observability port-forward svc/tempo 3200:3200 && curl localhost:3200/ready` | Verify OTLP endpoint reachable from app pods; check Tempo readiness |
| Alloy pods CrashLooping | `kubectl -n monitoring describe pod <alloy-pod>` | Check resource limits — Alloy may need more memory for large scrape targets |
| Prometheus out of memory | `kubectl -n observability top pod -l app.kubernetes.io/name=prometheus` | Increase memory limit or reduce scrape targets / retention |
| Loki query timeout | `kubectl -n observability logs deployment/loki --tail=20` | Reduce query time range; consider switching to `loki-distributed` |
| Grafana "No data" panels | Check data source configuration in Grafana UI | Verify service names match Helm release names in data source URLs |

### 4.3 Quick Reference Commands

```bash
# --- Alloy (Infrastructure) ---
kubectl -n monitoring get pods -l app=alloy-infra         # Check pod status
kubectl -n monitoring logs -l app=alloy-infra -f           # Stream logs
kubectl -n monitoring port-forward ds/alloy-infra 12345    # Alloy UI
curl -s localhost:12345/targets                            # Scrape targets

# --- Alloy (Application) ---
kubectl -n observability get pods -l app=alloy-app
kubectl -n observability logs -l app=alloy-app -f

# --- Prometheus ---
kubectl -n observability port-forward svc/kube-prometheus-kube-prome-prometheus 9090
# Open: http://localhost:9090/targets

# --- Loki ---
kubectl -n observability port-forward svc/loki 3100
# Test: curl -s localhost:3100/ready

# --- Grafana ---
kubectl -n observability get svc grafana                   # Get LoadBalancer IP
# Default: http://10.0.0.51:3000  admin/admin

# --- Talos node metrics (direct) ---
talosctl dashboard --nodes 10.0.0.10                       # Interactive TUI
talosctl health                                            # Cluster health check
talosctl logs kubelet --nodes 10.0.0.10                    # Kubelet logs
```

### 4.4 Capacity Planning

#### Grafana Cloud Free Tier Strategy

| Resource | Free Limit | Homelab Estimate | Strategy |
|----------|-----------|-----------------|----------|
| Metric series | 10,000 | ~3,000 (6 nodes + Proxmox + OPNsense) | Drop debug/internal metrics via relabeling |
| Logs | 50 GB/month | ~2 GB (infra logs only) | Only ship infra logs to cloud; app logs stay in-cluster |
| Traces | 50 GB/month | 0 (no infra traces needed) | Not used for platform plane |
| Retention | 14 days | Sufficient for infra | In-cluster stack handles longer retention needs |

#### In-Cluster Storage Estimation

| Component | Formula | Homelab Estimate |
|-----------|---------|-----------------|
| Prometheus | `series * bytes_per_series * retention_seconds` | ~500 series * 2 bytes * 604800s = ~600 MB for 7d |
| Loki | `log_volume_per_day * retention_days * compression_ratio` | ~500 MB/day * 7d * 0.1 = ~350 MB |
| Tempo | `traces_per_day * avg_span_size * retention_days` | Minimal until apps are instrumented |
| Total PVC | Sum of above + 50% headroom | **~10 GB per component is generous** |

> [!TIP]
> Start with 10Gi PVCs for each component. Monitor `kubelet_volume_stats_used_bytes` and expand before hitting 80%.

---

## 5. Further Reading

### Grafana Ecosystem

- [Grafana Cloud Documentation](https://grafana.com/docs/grafana-cloud/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/latest/)
- [Alloy River Configuration Reference](https://grafana.com/docs/alloy/latest/reference/config-blocks/)
- [Loki Best Practices](https://grafana.com/docs/loki/latest/best-practices/)
- [Tempo Getting Started](https://grafana.com/docs/tempo/latest/getting-started/)

### OpenTelemetry

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [OTel Collector Configuration](https://opentelemetry.io/docs/collector/)
- [OTel Kubernetes Operator](https://opentelemetry.io/docs/kubernetes/operator/)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otel/protocol/)

### SRE Practices

- [Google SRE Book — Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Google SRE Book — Service Level Objectives](https://sre.google/sre-book/service-level-objectives/)
- [Prometheus Alerting Best Practices](https://prometheus.io/docs/practices/alerting/)
- [Sloth — SLO Generation Tool](https://sloth.dev/)

### Repo Cross-References

- [architecture-diagrams.md](architecture-diagrams.md) — Network topology and IP allocation
- [argocd-setup-guide.md](argocd-setup-guide.md) — GitOps deployment patterns
- [talos-management-handbook.md](talos-management-handbook.md) — Talos operations and etcd management

---

*Last updated: 2026-03-20*
