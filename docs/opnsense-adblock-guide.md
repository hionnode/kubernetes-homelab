# OPNsense AdBlock Configuration Guide

Network-level ad blocking using OPNsense's Unbound DNS for a Kubernetes homelab.

**Applies to:** OPNsense 25.7+

---

## Overview

DNS-based ad blocking works by returning `0.0.0.0` or `NXDOMAIN` for known advertising, tracking, and malware domains. All devices on your network automatically benefit without requiring per-device configuration.

```
┌─────────────┐     DNS Query     ┌─────────────────┐
│   Client    │ ──────────────────│  OPNsense DNS   │
│  (Browser)  │                   │   (Unbound)     │
└─────────────┘                   └────────┬────────┘
                                           │
                    ┌──────────────────────┼──────────────────────┐
                    │                      │                      │
              ┌─────▼─────┐         ┌──────▼──────┐        ┌──────▼──────┐
              │ Blocklist │         │  Whitelist  │        │  Upstream   │
              │  Match?   │         │   Match?    │        │    DNS      │
              └─────┬─────┘         └──────┬──────┘        └──────┬──────┘
                    │                      │                      │
              Return 0.0.0.0          Allow query           Forward query
```

---

## Method 1: Unbound DNS Blocklist (Built-in)

The simplest approach using OPNsense's native Unbound DNS capabilities.

### Enable Unbound Blocklist

**Services → Unbound DNS → Blocklist**

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| Type of DNSBL | Unbound (default, fastest) |

### Select Blocklists

| List | Description | Domains |
|------|-------------|---------|
| Steven Black - Unified | Ads + malware | ~150k |
| AdGuard DNS | Comprehensive ads | ~50k |
| EasyList | Browser ad filter adapted | ~25k |
| Malware Domains | Security-focused | ~15k |
| No Coin | Cryptominer blocking | ~1k |

**Recommended starting point:** Steven Black Unified + AdGuard DNS

### Configure Blocklist Behavior

| Setting | Recommendation |
|---------|----------------|
| Destination Address | 0.0.0.0 (default) |
| Schedule | Daily at 03:00 |
| Log Queries | ✓ (for debugging) |

**Save → Apply**

### Verify Blocklist is Active

```bash
# From any LAN device
nslookup doubleclick.net 10.0.0.1
# Should return: 0.0.0.0
```

---

## Method 2: Adguard Home Plugin (Advanced)

For more control, logging, and per-client statistics.

### Install Plugin

**System → Firmware → Plugins**

Search and install: `os-adguardhome-maxit`

### Configure AdGuard Home

After installation: **Services → Adguardhome**

| Setting | Value |
|---------|-------|
| Enable | ✓ |
| Listen Address | 10.0.0.1 |
| Listen Port | 3000 (Web UI), 5353 (DNS) |

### Update Unbound to Forward to AdGuard

**Services → Unbound DNS → General**

| Setting | Value |
|---------|-------|
| DNS Query Forwarding | ✓ Enable |
| Custom Forwarding | 127.0.0.1:5353 |

### Access AdGuard Dashboard

```
http://10.0.0.1:3000
```

Features:
- Per-client statistics
- Real-time query log
- Custom filtering rules
- Parental controls
- Safe search enforcement

---

## Whitelist Management

### Adding Whitelisted Domains

**Services → Unbound DNS → Blocklist → Whitelist Domains**

Common services that may need whitelisting:

| Domain | Reason |
|--------|--------|
| s.youtube.com | YouTube history sync |
| *.apple.com | Apple services |
| *.microsoft.com | Windows updates |
| *.xbox.com | Xbox Live |
| *.sentry.io | App crash reporting |

### Regex Whitelisting

For multiple subdomains:
```
.*\.apple\.com$
.*\.icloud\.com$
```

---

## Custom Blocklists

### Adding Custom Block Domains

**Services → Unbound DNS → General → Host Overrides**

Add entries pointing to 0.0.0.0:

| Host | Domain | IP |
|------|--------|-----|
| ads | example.com | 0.0.0.0 |
| tracking | somesite.com | 0.0.0.0 |

### External Blocklist URLs

**Services → Unbound DNS → Blocklist → DNSBL**

Add custom URLs in "URLs of blocklists" field:

```
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt
```

---

## Kubernetes Integration

### Ensure Cluster DNS Uses OPNsense

Talos nodes should use OPNsense as DNS server. Verify DHCP leases have correct DNS:

**Services → DHCPv4 → LAN**

| Setting | Value |
|---------|-------|
| DNS Servers | 10.0.0.1 |

### CoreDNS Configuration

If pods need ad blocking, configure CoreDNS to forward to OPNsense:

```yaml
# In CoreDNS ConfigMap
forward . 10.0.0.1 {
    prefer_udp
}
```

> **Note:** Most workloads should use cluster DNS for service discovery. Ad blocking primarily benefits ingress traffic and developer machines.

---

## Monitoring & Statistics

### Query Logs

**Services → Unbound DNS → Advanced → Log Level**: Set to `1` or higher for query logging.

**View logs:** Services → Unbound DNS → Logs

### Blocked Query Count

Check Unbound statistics:
```bash
# OPNsense shell
unbound-control stats | grep num.queries.blocked
```

### Reporting Dashboard

**Reporting → Unbound DNS** (if available in your version)

View:
- Total queries
- Blocked percentage
- Top blocked domains
- Query sources

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No blocking after enable | Apply changes, wait 5 minutes for list download |
| Website broken | Check Unbound Logs, add to whitelist |
| Slow DNS resolution | Reduce blocklist size, enable caching |
| Mobile apps not working | Whitelist app-specific domains |
| Updates failing | Whitelist update servers (*.microsoft.com, etc.) |

### Force Blocklist Update

**Services → Unbound DNS → Blocklist → Download**

Or via command line:
```bash
configctl unbound dnsbl download
configctl unbound restart
```

### Test DNS Resolution

```bash
# Should be blocked (return 0.0.0.0)
dig @10.0.0.1 doubleclick.net +short

# Should resolve normally
dig @10.0.0.1 google.com +short
```

---

## Performance Considerations

| List Size | Memory Impact | Query Latency |
|-----------|---------------|---------------|
| < 100k | Minimal (~50MB) | < 1ms |
| 100k-500k | Moderate (~150MB) | 1-2ms |
| > 500k | Significant (~300MB+) | 2-5ms |

**Recommendations:**
- Start with ~100k domains (Steven Black Unified)
- Monitor memory usage via **Reporting → Health**
- Increase gradually if needed

---

## Further Reading

### Official Resources
- [OPNsense Unbound Blocklist](https://docs.opnsense.org/manual/unbound.html#blocklist)
- [Unbound DNS Documentation](https://nlnetlabs.nl/documentation/unbound/)

### Blocklist Sources
- [Steven Black Hosts](https://github.com/StevenBlack/hosts)
- [Hagezi DNS Blocklists](https://github.com/hagezi/dns-blocklists)
- [OISD Blocklist](https://oisd.nl/)
- [The Big Blocklist Collection](https://firebog.net/)

### Community
- [r/pihole](https://reddit.com/r/pihole) - Many discussions apply to DNS blocking
- [r/OPNsense](https://reddit.com/r/opnsense)
