resource "proxmox_virtual_environment_vm" "opnsense" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cores
  }

  memory {
    dedicated = var.vm_memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.vm_disk_size
    file_format  = "raw"
  }

  initialization {
      # No cloud-init for ISO install
  }

  # WAN Interface (Internet)
  network_device {
    bridge = "vmbr0"
  }

  # LAN Interface (Switch)
  network_device {
    bridge = "vmbr1"
  }
  
  # Set explicit boot order to prioritize CDROM (ide2 is default usually, let's assume cdrom interface below)
  # bpg/proxmox often uses 'order' string or list.
  # Checking recent docs, 'boot_order' is a list of device IDs.
  # We need to see what interface cdrom gets. The plan said 'ide3'.
  # So we set order to ["ide3", "scsi0", "net0"]
  
  boot_order = ["ide3", "scsi0"]

  cdrom {
     enabled = true
     file_id = proxmox_virtual_environment_download_file.opnsense_iso.id
     interface = "ide3" # Explicitly set interface to match boot order
  }

  operating_system {
    type = "l26" 
  }
}
