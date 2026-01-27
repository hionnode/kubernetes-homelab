# Talos Cluster Configuration
# First control plane node (talos-cp-1) as VM on Proxmox

# Generate cluster cryptographic secrets
resource "talos_machine_secrets" "this" {}

# Generate talosconfig for talosctl CLI access
data "talos_client_configuration" "this" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.talos_cp1_ip]
  nodes                = [var.talos_cp1_ip]
}

# Generate control plane machine configuration
data "talos_machine_configuration" "cp1" {
  cluster_name     = var.talos_cluster_name
  cluster_endpoint = "https://${var.talos_cluster_vip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda"
        }
        network = {
          hostname = var.talos_cp1_name
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              vip = {
                ip = var.talos_cluster_vip
              }
            }
          ]
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
        controllerManager = {
          extraArgs = {
            bind-address = "0.0.0.0"
          }
        }
        scheduler = {
          extraArgs = {
            bind-address = "0.0.0.0"
          }
        }
        proxy = {
          disabled = false
        }
        etcd = {
          extraArgs = {
            listen-metrics-urls = "http://0.0.0.0:2381"
          }
        }
      }
    })
  ]
}

# Create the VM on Proxmox
resource "proxmox_virtual_environment_vm" "talos_cp1" {
  name      = var.talos_cp1_name
  node_name = var.proxmox_node
  vm_id     = var.talos_cp1_vm_id

  machine = "q35"
  bios    = "seabios"

  cpu {
    cores = var.talos_cp_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.talos_cp_memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.talos_cp_disk_size
    file_format  = "raw"
  }

  cdrom {
    enabled   = true
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = false
  }

  on_boot = true
  started = true

  # Boot from CD first, then disk
  boot_order = ["ide2", "scsi0"]

  lifecycle {
    ignore_changes = [
      cdrom,
      boot_order
    ]
  }
}

# Apply Talos configuration to the booted VM
# This requires the VM to be running and accessible at the configured IP
resource "talos_machine_configuration_apply" "cp1" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp1.machine_configuration
  node                        = var.talos_cp1_ip
  endpoint                    = var.talos_cp1_ip

  depends_on = [proxmox_virtual_environment_vm.talos_cp1]
}
