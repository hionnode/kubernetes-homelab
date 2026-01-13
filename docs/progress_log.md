# Progress Log

## 2026-01-12

### Phase 1: OPNsense Terraform Setup

**Status**: Debugging `terraform apply` errors.

**Event 1: Credentials Error**
- **Error**: `Unable to create Proxmox VE API credentials`
- **Cause**: Terraform was not picking up `proxmox_username`/`password` from `terraform.tfvars`.
- **Resolution**: User updated `terraform.tfvars` correctly.

**Event 2: ISO Download Error**
- **Error**: 
  ```
  Error: Error initiating file download
  ...
  hostname lookup 'pve' failed - failed to get address info for: pve: Name or service not known
  ```
- **Analysis**:
  - The error occurs in `proxmox_virtual_environment_download_file`.
  - "hostname lookup 'pve' failed" suggests either the local machine (Terraform) or the Proxmox Node cannot resolve the hostname `pve`.
  - This typically occurs if `var.proxmox_node` is set to "pve" (default) but:
    1.  The actual Proxmox node has a different name.
    2.  The `proxmox_endpoint` uses an IP, but the provider attempts to resolve the node hostname for a specific datastore path.
    3.  The Proxmox node itself has a misconfigured `/etc/hosts`.

**Actions Scoped**:
1.  Verify `proxmox_node` matches the actual Datacenter node name.
**Event 3: ISO Compression Issue**
- **Issue**: OPNsense ISO is `.bz2` compressed. User request to handle extraction.
- **Investigation**: Checking if `proxmox_virtual_environment_download_file` supports `decompression_algorithm`.

**Event 4: Filename Extension Configuration Error**
- **Error**: `HTTP 400 ... filename: wrong file extension`
- **Cause**: Proxmox expects the target file to have a valid extension (e.g. `.iso`). Since the source is `.bz2`, we must explicitly set `file_name` to the desired output name.
- **Resolution**: Setting `file_name` in `iso.tf`.

**Event 5: Successful Deployment**
- **Status**: `terraform apply` completed successfully.
- **Outcome**: OPNsense VM created on Proxmox node. ISO downloaded and decompressed.
- **Next**: Manual OS installation and API Key generation.

**Event 6: Boot Failure (No Bootable Disk)**
- **Issue**: VM boots to SeaBIOS "Boot failed: not a bootable disk" then tries iPXE.
- **Cause**: VM is prioritizing Hard Disk (empty) over CDROM, or CDROM is disabled.
- **Investigation**: Plan output showed `cdrom { enabled = false }`. Need to enable it and set boot priority.
- **Resolution**: Updated `vm_opnsense.tf` to set `cdrom.enabled = true` and `boot_order = ["ide3", "scsi0"]`.

**Event 7: LAN IP Conflict**
- **Issue**: OPNsense default LAN IP `192.168.1.1` conflicts with the physical network router.
- **Action**: User must manually change LAN IP via Console (Option 2) to a non-conflicting IP (e.g., `192.168.1.50` or `192.168.2.1`).

**Event 8: Terraform Validation Failure**
- **Error**: `config_opnsense.tf` - `prio` not expected, `opnsense_interfaces_assignment` invalid.
- **Resolution**: Removing `prio`. Investigating correct resource name for interface assignment.

**Event 9: Ansible Module Error**
- **Error**: `couldn't resolve module/action 'ansibleguy.opnsense.interface'`
- **Cause**: The `ansibleguy.opnsense` collection does NOT have an `interface` assignment module (confirmed via `ansible-doc`).
- **Resolution**: Need to use `puzzle.opnsense` collection (which supports `interfaces_assignments`) or raw API calls.

**Event 10: Ansible DHCP Module Error**
- **Error**: `couldn't resolve module/action 'ansibleguy.opnsense.dhcp_interface'`
- **Cause**: Module does not exist in `ansibleguy` collection.
- **Investigation**: Checking `puzzle.opnsense` for DHCP configuration modules.

**Event 11: Missing Python Dependency**
- **Error**: `ModuleNotFoundError: No module named 'httpx'`
- **Cause**: The `ansibleguy.opnsense` collection requires `httpx` for API communication.
- **Resolution**: User must install it via `pip3 install httpx`.

**Event 12: Python Environment Mismatch**
- **Issue**: User installed `httpx` but Ansible still fails.
- **Hypothesis**: The `hosts.ini` forces `/usr/bin/python3`, but the user installed `httpx` in a different python (e.g., Homebrew or venv).
- **Action**: Identify correct python path and update inventory.

**Event 13: Persistent ModuleNotFoundError**
- **Issue**: `httpx` still not found even after user set `/opt/homebrew/bin/python3`.
- **Hypothesis**: Ansible (`pipx`) might be using its own venv, or `connection: local` behavior is tricky.
- **Action**: Running `debug_python.yml` to confirm exact interpreter.

**Event 14: Pipx Isolation Detected**
- **Issue**: Ansible is installed via `pipx` (found in `command_status` logs).
- **Cause**: Pipx uses an isolated venv. Packages installed in system python (`/opt/homebrew/bin/python3`) are NOT visible to Ansible.
- **Resolution**: Run `pipx inject ansible httpx` to install dependency into the ansible venv.

**Event 15: Missing Ansible Argument 'firewall'**
- **Error**: `missing required arguments: firewall`
- **Cause**: The `ansibleguy.opnsense` collection expects a dictionary named `firewall` containing url/api_key/secret, rather than flattened module args.
- **Resolution**: Construct `firewall` dict in playbook `vars` and pass it to modules.

**Event 16: Invalid Firewall Dict Format**
- **Error**: `Host ... is neither a valid IP nor Domain-Name`
- **Cause**: I passed `url` (e.g. `https://...`) but the module likely expects `ip` (hostname/IP only).
- **Resolution**: Updated playbook to regex-strip `https://` and use `ip` key.

**Event 17: Proxmox Bridge Configuration (Manual)**
- **Date**: 2026-01-12
- **Action**: Created vmbr1 bridge via SSH commands (bypassed stuck Ansible playbook)
- **Commands**:
  ```bash
  ssh root@192.168.1.110 "cat >> /etc/network/interfaces ..."
  ssh root@192.168.1.110 "ip link set enx1c860b363f63 up && ifreload -a"
  ```
- **Result**: vmbr1 UP, ready for OPNsense LAN interface

**Event 18: OPNsense Dual-NIC Terraform Update**
- **Date**: 2026-01-12
- **Action**: Added second `network_device` block to `vm_opnsense.tf`
- **Status**: `terraform apply` in progress (slow VM modification)
- **Future**: Consider using `qm set` for faster network changes
