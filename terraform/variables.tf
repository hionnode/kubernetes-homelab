variable "proxmox_endpoint" {
  description = "defines the proxmox endpoint"
  type        = string
  sensitive   = false
}

variable "proxmox_username" {
  description = "defines the proxmox username"
  type        = string
  sensitive   = false
}

variable "proxmox_password" {
  description = "promox user password"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "promox node that we're going to use"
  type        = string
  sensitive   = false
}

variable "vm_id" {
  description = "id for opnsens vm"
  type        = string
  sensitive   = false
}

variable "vm_name" {
  description = "name for the opnsense vm"
  type        = string
  sensitive   = false
}

variable "vm_memory" {
  description = "memory alloted to the opnsense vm"
  type        = number
  sensitive   = false
  default     = 2048
}

variable "vm_cores" {
  description = "cpu cores alloted to opnsens vm"
  type        = number
  sensitive   = false
  default     = 2
}

variable "vm_disk_size" {
  description = "vm disk size"
  type        = number
  sensitive   = false
  default     = 16
}


# variable "iso_file_id" {
#   description = "ISO file ID for OPNsense (e.g. local:iso/OPNsense.iso)"
#   type = string
#   sensitive = false
# }


variable "opnsense_uri" {
  description = "URI for OPNsense API (e.g. https://192.168.1.1)"
  type        = string
  sensitive   = false
  default     = "https://192.168.1.1" # Default fallback, user should override
}

variable "opnsense_api_key" {
  description = "OPNsense API Key"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNsense API Secret"
  type        = string
  sensitive   = true
}


variable "opnsense_iso_url" {
  description = "URL to download OPNsense ISO"
  type        = string
  sensitive   = false
  default     = "https://pkg.opnsense.org/releases/25.7/OPNsense-25.7-dvd-amd64.iso.bz2"
}

variable "network_bridge" {
  description = "Network bridge to use (e.g. vmbr0)"
  type        = string
  sensitive   = false
  default     = "vmbr0"
}

# Talos Cluster Variables
variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.9.0"
}

variable "kubernetes_version" {
  description = "Kubernetes version for Talos cluster"
  type        = string
  default     = "1.31.0"
}

variable "talos_cluster_name" {
  description = "Name of the Talos Kubernetes cluster"
  type        = string
  default     = "homelab-cluster"
}

variable "talos_cluster_vip" {
  description = "Virtual IP for Kubernetes API high availability"
  type        = string
  default     = "10.0.0.5"
}

variable "talos_cp1_vm_id" {
  description = "Proxmox VM ID for talos-cp-1"
  type        = number
  default     = 200
}

variable "talos_cp1_name" {
  description = "VM name for the first Talos control plane"
  type        = string
  default     = "talos-cp-1"
}

variable "talos_cp1_ip" {
  description = "IP address for talos-cp-1 (via DHCP reservation)"
  type        = string
  default     = "10.0.0.10"
}

variable "talos_cp_memory" {
  description = "Memory (MB) for Talos control plane VMs"
  type        = number
  default     = 4096
}

variable "talos_cp_cores" {
  description = "CPU cores for Talos control plane VMs"
  type        = number
  default     = 2
}

variable "talos_cp_disk_size" {
  description = "Disk size (GB) for Talos control plane VMs"
  type        = number
  default     = 32
}