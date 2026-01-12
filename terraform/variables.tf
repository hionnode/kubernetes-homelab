variable "proxmox_endpoint" {
    description = "defines the proxmox endpoint"
    type = string
    sensitive = false
}

variable "proxmox_username" {
    description = "defines the proxmox username"
    type = string
    sensitive = false
}

variable "proxmox_password" {
    description = "promox user password"
    type = string
    sensitive = true
}

variable "proxmox_node" {
  description = "promox node that we're going to use"
  type = string
  sensitive = false
}

variable "vm_id" {
  description = "id for opnsens vm"
  type = string
  sensitive = false
}

variable "vm_name" {
  description = "name for the opnsense vm"
  type = string
  sensitive = false
}

variable "vm_memory" {
  description = "memory alloted to the opnsense vm"
  type = number
  sensitive = false
  default = 2048
}

variable "vm_cores" {
  description = "cpu cores alloted to opnsens vm"
  type = number
  sensitive = false
  default = 2
}

variable "vm_disk_size" {
  description = "vm disk size"
  type = number
  sensitive = false
  default = 16
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
  type = string
  sensitive = false
  default = "vmbr0"
}