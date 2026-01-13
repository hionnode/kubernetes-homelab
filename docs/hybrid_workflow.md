# Homelab Hybrid Workflow Guide

## Tool Selection Matrix

### Terraform
**Use for:**
- Initial VM creation
- VM destruction/cleanup
- Disk provisioning
- ISO downloads to Proxmox
- Major infrastructure topology changes

**Avoid for:**
- Runtime VM modifications (slow)
- Quick network changes
- Iterative testing

### Ansible
**Use for:**
- Application configuration (OPNsense, Talos)
- Multi-step orchestration
- Idempotent operations
- Configuration templates
- State-based configuration

**Avoid for:**
- One-off quick fixes
- Operations requiring immediate feedback

### Bash/SSH (qm commands)
**Use for:**
- Quick VM modifications (`qm set`)
- One-off changes during development
- Debugging and verification
- Operations needing <5 second execution

**Avoid for:**
- Complex multi-step workflows
- Production deployments

---

## Workflow Examples

### Adding a Network Interface
**Development (Fast):**
```bash
ssh root@proxmox "qm set <vmid> -net1 virtio,bridge=vmbr1"
```

**Production (Tracked):**
```hcl
# Update vm_opnsense.tf
network_device { bridge = "vmbr1" }
# Then: terraform apply
```

### OPNsense Configuration
**Always use Ansible** for consistency and repeatability.

### Proxmox Host Changes
**Bash for speed**, document in progress_log.md

---

## Documentation Standard

Every manual operation (bash/ssh) must be logged in:
- `progress_log.md` (what/when/why)
- Corresponding Terraform code (commented or in variables.tf notes)

This ensures we can recreate the environment from scratch if needed.
