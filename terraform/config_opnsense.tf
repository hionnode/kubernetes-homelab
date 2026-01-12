# OPNsense Configuration
# Note: This requires the OPNsense VM to be up and API configured.

# Example: Define VLAN 10 for Kubernetes Cluster
# resource "opnsense_interfaces_vlan" "kube_vlan" {
#   device = "vlan01"
#   tag    = 10
#   prio   = 0
#   parent = "vtnet1" # Adjust based on your interface (LAN)
#   description = "Kubernetes Cluster VLAN"
# }

# Example: Assign VLAN to Interface
# resource "opnsense_interfaces_assignment" "kube_interface" {
#   device      = opnsense_interfaces_vlan.kube_vlan.device
#   description = "KUBE_NET"
# }

# Example: DHCP Static Map
# resource "opnsense_dhcp_static_map" "control_plane_1" {
#   interface = "lan" # or the UUID/name of KUBE_NET
#   mac       = "00:00:00:00:00:01"
#   ipaddr    = "192.168.1.11"
#   hostname  = "cp-01"
# }

# Placeholder for now - uncomment and customize after Phase 1 VM deployment
