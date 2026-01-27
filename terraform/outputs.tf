# Talos Cluster Outputs

output "talosconfig" {
  description = "Talos client configuration for talosctl"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "talos_cp1_vm_id" {
  description = "VM ID of talos-cp-1"
  value       = proxmox_virtual_environment_vm.talos_cp1.vm_id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = "https://${var.talos_cluster_vip}:6443"
}

output "talos_cp1_mac_address" {
  description = "MAC address of talos-cp-1 (for DHCP reservation)"
  value       = proxmox_virtual_environment_vm.talos_cp1.network_device[0].mac_address
}
