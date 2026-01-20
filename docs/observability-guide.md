# Kubernetes Homelab Observability Guide

Two-tier observability strategy: Grafana Cloud for infrastructure monitoring and in-cluster Grafana/SigNoz for application observability.

---

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                           GRAFANA CLOUD                                        │
│                    (Infrastructure Monitoring)                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                            │
│  │   Grafana   │  │    Mimir    │  │    Loki     │                            │
│  │ Dashboards  │  │   Metrics   │  │    Logs     │                            │
│  └─────────────┘  └──────▲──────┘  └──────▲──────┘                            │
└──────────────────────────┼────────────────┼───────────────────────────────────┘
                           │                │
         ┌─────────────────┼────────────────┼─────────────────┐
         │                 │                │                 │
    ┌────┴────┐      ┌─────┴─────┐    ┌─────┴─────┐     ┌─────┴─────┐
    │ Proxmox │      │   Talos   │    │ OPNsense  │     │  Alloy    │
    │  Host   │      │   Nodes   │    │  Router   │     │ (on K8s)  │
    └─────────┘      └───────────┘    └───────────┘     └───────────┘

┌───────────────────────────────────────────────────────────────────────────────┐
│                        KUBERNETES CLUSTER                                      │
│                    (Application Observability)                                 │
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │                    Grafana / SigNoz Stack                               │  │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────────────┐    │  │
│  │  │  Grafana  │  │Prometheus │  │   Loki    │  │ Tempo / ClickHouse│    │  │
│  │  │    UI     │  │  Metrics  │  │   Logs    │  │     Traces        │    │  │
│  │  └───────────┘  └─────▲─────┘  └─────▲─────┘  └─────────▲─────────┘    │  │
│  └───────────────────────┼──────────────┼──────────────────┼──────────────┘  │
│                          │              │                  │                  │
│              ┌───────────┴──────────────┴──────────────────┴───────────┐     │
│              │              Your Applications                           │     │
│              │     (metrics, logs, traces via OTLP/Prometheus)         │     │
│              └──────────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Why Two Tiers?**
- **Grafana Cloud**: Always-on external visibility for infrastructure, survives cluster failures
- **In-cluster**: Full control, no egress costs, richer application debugging

---

## Part 1: Infrastructure Monitoring (Grafana Cloud)

### What Gets Monitored Here
- **Proxmox**: Host metrics, VM status, storage
- **Talos**: Node health, kubelet, etcd
- **OPNsense**: Firewall metrics, interface stats, DNS queries

### 1.1 Grafana Cloud Setup

#### Create Free Account

1. Sign up at [grafana.com/cloud](https://grafana.com/cloud)
2. Create a new stack (e.g., `homelab-infra`)
3. Note down:
   - Grafana URL: `https://<stack>.grafana.net`
   - Prometheus endpoint: `https://prometheus-<region>.grafana.net/api/prom/push`
   - Loki endpoint: `https://logs-<region>.grafana.net/loki/api/v1/push`

#### Generate Access Tokens

1. **Administration → Cloud Access Policies**
2. Create policy with scopes: `metrics:write`, `logs:write`
3. Generate token and save securely

### 1.2 Proxmox Monitoring

#### Install Prometheus Metrics Exporter

On Proxmox host:

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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pve-exporter
```

#### Install Alloy on Proxmox

```bash
# Add Grafana repo
apt-get install -y gpg
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/grafana.gpg
echo "deb https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list

apt update && apt install alloy -y
```

Configure `/etc/alloy/config.alloy`:
```hcl
prometheus.scrape "proxmox" {
  targets = [{"__address__" = "localhost:9221"}]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}

prometheus.scrape "node" {
  targets = [{"__address__" = "localhost:9100"}]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}

prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "https://prometheus-prod-xx-xxx.grafana.net/api/prom/push"
    basic_auth {
      username = "<instance-id>"
      password = "<api-key>"
    }
  }
}
```

```bash
systemctl enable --now alloy
```

### 1.3 OPNsense Monitoring

#### Enable Built-in Exporter

**System → Settings → Miscellaneous → Netflow**

Or install the Prometheus exporter plugin:

**System → Firmware → Plugins → os-prometheus-exporter**

After install: **Services → Prometheus Exporter**

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| Listen Address | LAN address |
| Listen Port | 9100 |

#### Scrape from Alloy (in-cluster or on Proxmox)

Add to Alloy config:
```hcl
prometheus.scrape "opnsense" {
  targets = [{"__address__" = "10.0.0.1:9100"}]
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  scrape_interval = "30s"
}
```

### 1.4 Talos Node Monitoring

Talos exposes metrics on each node at port 9100.

#### Deploy Alloy DaemonSet for Node Metrics

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: alloy-infra
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: alloy-infra
  template:
    metadata:
      labels:
        app: alloy-infra
    spec:
      hostNetwork: true
      containers:
        - name: alloy
          image: grafana/alloy:latest
          args:
            - run
            - /etc/alloy/config.alloy
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
      volumes:
        - name: config
          configMap:
            name: alloy-infra-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-infra-config
  namespace: monitoring
data:
  config.alloy: |
    prometheus.scrape "kubelet" {
      targets = [{"__address__" = "localhost:10250"}]
      scheme = "https"
      tls_config {
        insecure_skip_verify = true
      }
      bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      forward_to = [prometheus.remote_write.grafana_cloud.receiver]
    }
    
    prometheus.remote_write "grafana_cloud" {
      endpoint {
        url = "https://prometheus-prod-xx-xxx.grafana.net/api/prom/push"
        basic_auth {
          username = "<instance-id>"
          password = "<api-key>"
        }
      }
      external_labels = {
        cluster = "homelab",
      }
    }
```

### 1.5 Infrastructure Dashboards

Import these dashboards in Grafana Cloud:

| Dashboard ID | Name | For |
|--------------|------|-----|
| `10347` | Proxmox VE | Proxmox host/VMs |
| `1860` | Node Exporter Full | All Linux hosts |
| `12644` | OPNsense | Firewall metrics |
| `6417` | Kubernetes Pods | Basic pod view |

### 1.6 Infrastructure Alerts

| Alert | Query | Severity |
|-------|-------|----------|
| Proxmox Host Down | `up{job="proxmox"} == 0` | Critical |
| Talos Node NotReady | `kube_node_status_condition{condition="Ready",status="true"} == 0` | Critical |
| OPNsense High CPU | `avg(rate(node_cpu_seconds_total{instance=~".*opnsense.*",mode!="idle"}[5m])) > 0.8` | Warning |
| Disk Space Low | `node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.15` | Warning |
| etcd Cluster Unhealthy | `etcd_server_has_leader == 0` | Critical |

---

## Part 2: Application Observability (In-Cluster)

Deploy a full observability stack inside your cluster for application monitoring.

### 2.1 Option A: Grafana Stack (LGTM)

Loki + Grafana + Tempo + Mimir - full open-source stack.

#### Install with Helm

```bash
# Add Helm repos
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace observability

# Install Loki (logs)
helm install loki grafana/loki \
  --namespace observability \
  --set loki.auth_enabled=false \
  --set singleBinary.replicas=1

# Install Tempo (traces)
helm install tempo grafana/tempo \
  --namespace observability \
  --set tempo.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317 \
  --set tempo.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318

# Install Prometheus (metrics)
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --set grafana.enabled=false  # We'll install Grafana separately

# Install Grafana
helm install grafana grafana/grafana \
  --namespace observability \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set adminPassword=admin
```

#### Configure Grafana Data Sources

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
        url: http://prometheus-kube-prometheus-prometheus:9090
        isDefault: true
      - name: Loki
        type: loki
        url: http://loki:3100
      - name: Tempo
        type: tempo
        url: http://tempo:3100
```

### 2.2 Option B: SigNoz (All-in-One)

Single platform for metrics, logs, and traces with built-in dashboards.

#### Install SigNoz

```bash
# Add SigNoz Helm repo
helm repo add signoz https://charts.signoz.io
helm repo update

# Install SigNoz
helm install signoz signoz/signoz \
  --namespace observability \
  --create-namespace \
  --set global.storageClass=<your-storage-class> \
  --set clickhouse.persistence.size=20Gi
```

#### Access SigNoz UI

```bash
kubectl -n observability port-forward svc/signoz-frontend 3301:3301
```

Open: `http://localhost:3301`

#### SigNoz Features
- OpenTelemetry-native (OTLP receiver built-in)
- ClickHouse backend (efficient storage)
- Built-in APM dashboards
- Exception tracking
- Log management

### 2.3 Instrument Applications

Configure apps to send telemetry to your in-cluster stack.

#### Environment Variables

For Grafana Stack (Tempo):
```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://tempo.observability.svc:4317"
  - name: OTEL_SERVICE_NAME
    value: "myapp"
```

For SigNoz:
```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.observability.svc:4317"
  - name: OTEL_SERVICE_NAME
    value: "myapp"
```

#### ServiceMonitor for Prometheus Metrics

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp-metrics
  namespace: observability
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

#### Example: Python App with OpenTelemetry

```python
# requirements.txt
opentelemetry-distro
opentelemetry-exporter-otlp

# Auto-instrumentation
opentelemetry-instrument python app.py
```

### 2.4 Log Collection

#### Promtail DaemonSet (for Loki)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: observability
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      containers:
        - name: promtail
          image: grafana/promtail:latest
          args:
            - -config.file=/etc/promtail/promtail.yaml
          volumeMounts:
            - name: logs
              mountPath: /var/log
            - name: config
              mountPath: /etc/promtail
      volumes:
        - name: logs
          hostPath:
            path: /var/log
        - name: config
          configMap:
            name: promtail-config
```

### 2.5 Useful Queries

#### Prometheus (PromQL)

```promql
# Request rate by service
sum(rate(http_requests_total[5m])) by (service)

# Error percentage
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) * 100

# P99 latency
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
```

#### Loki (LogQL)

```logql
# All errors from production namespace
{namespace="production"} |= "error"

# Parse JSON logs and filter by level
{namespace="production"} | json | level="error"

# Count errors per service
sum by (app) (count_over_time({namespace="production"} |= "error" [5m]))
```

---

## Part 3: Alerting

### 3.1 Grafana Cloud Alerting

#### Create Alert Rules

**Alerting → Alert rules → New alert rule**

Example: High Memory Usage
```promql
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
```

#### Contact Points

Configure notifications:
- **Email**: Built-in
- **Slack**: Webhook URL
- **PagerDuty**: Integration key
- **Discord**: Webhook

### 3.2 Essential Alerts

| Alert | Query | Severity |
|-------|-------|----------|
| Node Down | `up{job="node"} == 0` | Critical |
| High CPU | `node_cpu_usage > 85` for 10m | Warning |
| Pod CrashLoop | `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0` | Critical |
| PVC Almost Full | `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.9` | Warning |
| Certificate Expiring | `probe_ssl_earliest_cert_expiry - time() < 86400 * 14` | Warning |

---

## Part 4: Dashboards

### 4.1 Recommended Dashboard Structure

```
📊 Grafana Dashboards
├── 🏠 Home
│   └── Cluster Overview
├── 📦 Infrastructure
│   ├── Nodes
│   ├── Namespaces
│   └── Storage
├── 🚀 Applications
│   ├── Service A
│   ├── Service B
│   └── Ingress/Gateway
└── 🔍 Debugging
    ├── Logs Explorer
    └── Trace Explorer
```

### 4.2 Custom Dashboard Template

```json
{
  "panels": [
    {
      "title": "Request Rate",
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{namespace=\"$namespace\"}[5m])) by (service)"
        }
      ]
    },
    {
      "title": "Error Rate",
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))"
        }
      ]
    },
    {
      "title": "P99 Latency",
      "targets": [
        {
          "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))"
        }
      ]
    }
  ]
}
```

---

## Quick Reference

### Useful Commands

```bash
# Check Alloy status
kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy

# View Alloy logs
kubectl -n monitoring logs -l app.kubernetes.io/name=alloy -f

# Port-forward to Alloy UI (if enabled)
kubectl -n monitoring port-forward svc/alloy 12345:12345

# Test Prometheus scrape targets
kubectl -n monitoring exec -it deploy/alloy -- wget -qO- localhost:12345/targets
```

### Grafana Cloud Free Tier Limits

| Component | Free Limit |
|-----------|------------|
| Metrics | 10,000 series |
| Logs | 50 GB/month |
| Traces | 50 GB/month |
| Users | 3 |
| Retention | 14 days |

> **Tip:** Use recording rules to reduce cardinality and stay within limits.

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| No metrics in Grafana | Alloy pods running, credentials correct |
| Missing logs | Alloy has access to /var/log, Loki endpoint works |
| High cardinality | Check metric labels, add relabeling rules |
| Traces not appearing | OTLP endpoint reachable, auth configured |

---

## Further Reading

### Grafana Cloud
- [Grafana Cloud Docs](https://grafana.com/docs/grafana-cloud/)
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
- [Kubernetes Monitoring](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/)

### OpenTelemetry
- [OTel Collector](https://opentelemetry.io/docs/collector/)
- [OTel Kubernetes](https://opentelemetry.io/docs/kubernetes/)

### Best Practices
- [Prometheus Naming](https://prometheus.io/docs/practices/naming/)
- [Loki Best Practices](https://grafana.com/docs/loki/latest/best-practices/)
- [Distributed Tracing Guide](https://grafana.com/docs/tempo/latest/getting-started/best-practices/)
