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

  network_device {
    bridge = var.network_bridge
  }
  
  cdrom {
     file_id = var.iso_file_id
  }

  operating_system {
    type = "l26" 
  }
}
