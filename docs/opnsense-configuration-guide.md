# OPNsense 25.7 Configuration Guide

UI-focused configuration guide for OPNsense 25.7 managing a Kubernetes homelab.

**Version:** OPNsense 25.7, FreeBSD 14.3-RELEASE-p1, OpenSSL 3.0.17

---

## Quick Access

```
Web GUI: https://<WAN-IP>
Default Login: root / opnsense
```

---

## 1. Initial System Setup

### System → Settings → General

| Setting | Value |
|---------|-------|
| Hostname | opnsense |
| Domain | homelab.local |
| Timezone | Your timezone |
| DNS Servers | 1.1.1.1, 8.8.8.8 |

**Save → Apply**

### System → Settings → Administration

| Section | Setting |
|---------|---------|
| Web GUI | Protocol: HTTPS |
| | TCP Port: 443 |
| | Listen Interfaces: All |
| Secure Shell | Enable: ✓ |
| | Root Login: ✓ Permit |
| | Port: 22 |

---

## 2. Interface Configuration

### Interfaces → Assignments

Verify mapping:
- **WAN** → vtnet0 (external network)
- **LAN** → vtnet1 (internal/switch network)

### Interfaces → WAN

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| IPv4 Configuration | DHCP |
| Block private networks | ✓ (recommended) |
| Block bogon networks | ✓ (recommended) |

### Interfaces → LAN

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| IPv4 Configuration | Static IPv4 |
| IPv4 Address | 10.0.0.1 / 24 |

---

## 3. DHCP Server

### Services → DHCPv4 → LAN

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| Range | From: 10.0.0.100 To: 10.0.0.200 |
| DNS Servers | 10.0.0.1 (or 1.1.1.1) |
| Gateway | 10.0.0.1 |
| Domain name | homelab.local |
| Lease time | 86400 (1 day) |

### DHCP Static Mappings (for Talos nodes)

Scroll down to **DHCP Static Mappings** → Click **+**

| MAC Address | IP Address | Hostname | Description |
|-------------|------------|----------|-------------|
| (VM MAC) | 10.0.0.10 | talos-cp-1 | Control Plane 1 |
| (Physical) | 10.0.0.11 | talos-cp-2 | Control Plane 2 |
| (Physical) | 10.0.0.12 | talos-cp-3 | Control Plane 3 |
| (Physical) | 10.0.0.20 | talos-worker-1 | Worker 1 |
| (Physical) | 10.0.0.21 | talos-worker-2 | Worker 2 |
| (Physical) | 10.0.0.22 | talos-worker-3 | Worker 3 |

> **Tip:** Get MAC addresses from Proxmox VM config or boot physical nodes and check Services → DHCPv4 → Leases

---

## 4. Firewall Configuration

### Firewall → NAT → Outbound

| Setting | Value |
|---------|-------|
| Mode | Automatic outbound NAT |

This automatically creates rules for LAN → WAN traffic.

### Firewall → Rules → LAN

Default rules should allow LAN to any. If missing:

**Add Rule (+):**
| Setting | Value |
|---------|-------|
| Action | Pass |
| Interface | LAN |
| Direction | in |
| TCP/IP Version | IPv4+IPv6 |
| Protocol | any |
| Source | LAN net |
| Destination | any |
| Description | Allow LAN to any |

### Firewall → Rules → WAN

**Default:** Block all incoming (correct for security)

**For Kubernetes LoadBalancer services** (if exposing externally later):

**Add Rule (+):**
| Setting | Value |
|---------|-------|
| Action | Pass |
| Interface | WAN |
| Protocol | TCP |
| Destination | LAN net |
| Destination Port | (service port) |
| Description | Allow external to K8s service |

---

## 5. DNS Resolver (Unbound)

### Services → Unbound DNS → General

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| Listen Port | 53 |
| Network Interfaces | LAN, Localhost |
| DNSSEC | ✓ Enable |
| DNS Query Forwarding | ✓ Enable (use system nameservers) |

### Services → Unbound DNS → Host Overrides

Add local DNS entries for your cluster:

| Host | Domain | IP |
|------|--------|-----|
| talos-cp-1 | homelab.local | 10.0.0.10 |
| talos-cp-2 | homelab.local | 10.0.0.11 |
| talos-cp-3 | homelab.local | 10.0.0.12 |
| k8s-api | homelab.local | 10.0.0.5 |

---

## 6. API Access (for Automation)

### System → Access → Users

Edit **root** user (or create dedicated API user):

1. Scroll to **API keys** section
2. Click **+** to generate
3. **Download** and save both:
   - Key (username for API)
   - Secret (password for API)

**Store securely:**
```bash
# ~/.bashrc or environment
export OPNSENSE_API_KEY="your-key"
export OPNSENSE_API_SECRET="your-secret"
```

### System → Access → Groups

For dedicated API user, ensure membership in **admins** group.

---

## 7. Monitoring & Logs

### Reporting → Health

View real-time graphs:
- CPU usage
- Memory usage
- Disk usage
- Network throughput

### Reporting → NetFlow

Enable for traffic analysis:
1. Interfaces → Select LAN, WAN
2. Capture: Local

### System → Log Files

Key logs:
- **System** → General system events
- **Firewall** → Blocked/allowed traffic
- **DHCP** → Lease activity
- **DNS** → Query logs (if enabled)

---

## 8. Backup & Restore

### System → Configuration → Backups

| Action | Steps |
|--------|-------|
| **Manual Backup** | Download → Download configuration |
| **Restore** | Restore → Upload file → Restore |
| **Auto Backup** | Setup → Google Drive/Nextcloud |

**Recommendation:** Download backup after each major change.

---

## 9. Updates

### System → Firmware → Status

- View current version
- Check for updates
- **Update** button to apply

### System → Firmware → Settings

| Setting | Recommendation |
|---------|----------------|
| Mirror | Default or nearest |
| Flavour | OpenSSL (default) |
| Release Type | Production |

---

## 10. Useful Plugins

### System → Firmware → Plugins

**Recommended for homelab:**

| Plugin | Purpose |
|--------|---------|
| os-acme-client | Let's Encrypt certificates |
| os-haproxy | Load balancing, reverse proxy |
| os-theme-* | UI themes |
| os-vnstat | Bandwidth monitoring |
| os-wazuh-agent | Security monitoring |

---

## Network Diagram

```
Internet
    │
Main Router (192.168.1.1)
    │
    ├── Proxmox Management (192.168.1.110)
    │
    └── OPNsense WAN (192.168.1.x via DHCP)
            │
       [VM 101: OPNsense 25.7]
            │
       OPNsense LAN (10.0.0.1/24)
            │
       TP-Link Switch
            │
       ├── 10.0.0.5 (VIP) ─── Kubernetes API
       ├── 10.0.0.10-12 ───── Control Planes
       ├── 10.0.0.20-22 ───── Workers
       └── 10.0.0.100-200 ─── DHCP Pool
```

---

## Quick Troubleshooting

| Issue | Check |
|-------|-------|
| No internet on LAN | Firewall → NAT → Outbound mode |
| DNS not working | Services → Unbound → Enable |
| DHCP not assigning | Services → DHCPv4 → Enable |
| Can't reach OPNsense | Interfaces → LAN → correct IP |
| SSH not working | System → Admin → SSH enabled |

---

## Further Reading

### Official Documentation
- [OPNsense Docs](https://docs.opnsense.org/) - Complete reference
- [OPNsense 25.7 Release Notes](https://docs.opnsense.org/releases.html)
- [Firewall Rules](https://docs.opnsense.org/manual/firewall.html)
- [NAT Configuration](https://docs.opnsense.org/manual/nat.html)
- [DHCP Server](https://docs.opnsense.org/manual/dhcp.html)
- [Unbound DNS](https://docs.opnsense.org/manual/unbound.html)
- [API Reference](https://docs.opnsense.org/development/api.html)

### Community Resources
- [OPNsense Forum](https://forum.opnsense.org/)
- [OPNsense Reddit](https://reddit.com/r/opnsense)
- [Awesome OPNsense](https://github.com/unl0ck/awesome-opnsense)

### Kubernetes Integration
- [MetalLB + OPNsense](https://metallb.universe.tf/)
- [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/)
- [K8s Ingress with HAProxy](https://docs.opnsense.org/manual/how-tos/haproxy.html)

### Video Tutorials
- [Lawrence Systems](https://www.youtube.com/@LawrenceSystems) - OPNsense deep dives
- [Techno Tim](https://www.youtube.com/@TechnoTim) - Homelab setups
