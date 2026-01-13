# Homelab Full Implementation Plan (Ansible Pivot)

## Architecture
- **Provisioning**: Terraform (`bpg/proxmox`, `siderolabs/talos`).
- **Configuration (OPNsense)**: Ansible (`ansibleguy.opnsense`).

---

## Phase 1: Network Infrastructure (OPNsense)

### 1.1 VM Provisioning (Terraform) - **DONE**
- VM created, ISO auto-downloaded, generic config.
- User has manually installed OS and generated API keys.

### 1.2 OPNsense Configuration (Ansible)
- **Goal**: Configure VLANs, Assignments, and DHCP programmatically.
- **Collection**: `ansibleguy.opnsense` (Community standard for OPNsense).
- **Structure**:
    - `ansible/inventory/hosts.ini`: Define OPNsense connection (IP, API Key, Secret).
    - `ansible/playbooks/site.yml`: Main playbook.
- **Tasks**:
    1.  **VLANs**: Create VLAN 10 (Kubernetes).
    2.  **Interfaces**: Assign VLAN 10 to a logical interface (e.g., `opt1` -> `KUBE_NET`).
    3.  **DHCP**: Enable DHCP on `KUBE_NET`.
    4.  **Firewall**: Allow simplified rules for Homelab (Allow All on KUBE_NET initially).

---

## Phase 2: Talos Cluster Bootstrap (Terraform)
- **Provider**: `siderolabs/talos`.
- **Workflow**:
    1.  Generate Secrets & Configs.
    2.  Provision Control Plane VM (Proxmox).
    3.  Bootstrap Cluster.
