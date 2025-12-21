# Kubernetes Homelab

This repo contains all the code and steps that I followed in setting up my homelab which is running talos

Infrastructure as Code for Proxmox + OPNsense homelab.

## Structure
```
.
├── terraform/      # VM provisioning
├── ansible/        # Host configuration
│   ├── inventory/  # Host definitions
│   ├── playbooks/  # Task definitions
│   └── roles/      # Reusable components
└── docs/           # Documentation
```

## Quick Start

1. Configure AWS credentials
2. Update `terraform/terraform.tfvars`
3. Update `ansible/inventory/hosts.yml`
4. Run: `cd terraform && terraform init && terraform apply`
5. Run: `cd ansible && ansible-playbook playbooks/site.yml`
