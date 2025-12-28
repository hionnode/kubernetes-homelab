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