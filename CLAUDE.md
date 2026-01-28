# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure as Code for a Kubernetes homelab running Talos Linux on Proxmox with OPNsense as the network gateway. The architecture uses a hybrid VM + physical node topology with GitOps deployment via ArgoCD.

## Repository Structure

- `terraform/` - Infrastructure provisioning (Proxmox VMs, OPNsense config, Talos cluster)
- `ansible/` - Configuration management (OPNsense orchestration)
- `scripts/` - Bash automation for quick development iterations
- `docs/` - Architecture diagrams, setup guides, operational logs

## Commands

### Terraform (Infrastructure)

```bash
# Initialize (requires AWS credentials for S3 backend)
cd terraform && terraform init

# Plan/apply changes
terraform plan
terraform apply

# Target specific resources
terraform apply -target=proxmox_virtual_environment_vm.opnsense
```

### Ansible (Configuration)

```bash
cd ansible
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/opnsense.yml  # OPNsense only
```

### Talos (Kubernetes)

```bash
talosctl --talosconfig=./talosconfig config endpoint 10.0.0.10
talosctl health
talosctl kubeconfig
kubectl get nodes
```

## Tool Selection (When to Use What)

**Terraform**: VM creation/destruction, disk provisioning, ISO downloads, major topology changes

**Ansible**: Application configuration, multi-step orchestration, idempotent operations, templates

**Bash/SSH**: Quick VM modifications during development (`qm set`), debugging, one-off changes

Document all manual SSH operations in `docs/progress_log.md`.

## Network Architecture

- **WAN**: 192.168.1.0/24 (main router network)
- **LAN**: 10.0.0.0/24 (Kubernetes network via OPNsense)
- **K8s API VIP**: 10.0.0.5
- **Control Planes**: 10.0.0.10-12 (1 VM + 2 physical)
- **Workers**: 10.0.0.20-22 (3 physical)
- **MetalLB Pool**: 10.0.0.50-99

See `docs/architecture-diagrams.md` for detailed topology diagrams.

## Configuration

Copy example files before configuring:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
```

Required variables:
- Proxmox endpoint/credentials
- OPNsense API key/secret
- AWS credentials (for Terraform S3 state backend)

## Terraform Providers

- `bpg/proxmox` ~0.70.0 - Proxmox VE management
- `browningluke/opnsense` ~0.11.0 - OPNsense firewall config
- `siderolabs/talos` ~0.7.0 - Talos Linux cluster

## Key Files

- `terraform/vm_opnsense.tf` - OPNsense VM definition
- `terraform/cluster_talos.tf` - Talos cluster configuration
- `terraform/config_opnsense.tf` - OPNsense firewall rules/DHCP
- `docs/talos-setup-guide.md` - Manual Talos bootstrap steps
- `docs/progress_log.md` - Operational history (log manual changes here)
