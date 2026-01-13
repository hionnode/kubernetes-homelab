# OPNsense Configuration
# Note: This requires the OPNsense VM to be up and API configured.

# Define VLAN 10 for Kubernetes Cluster
resource "opnsense_interfaces_vlan" "kube_vlan" {
  device   = "vlan0.10"
  tag      = 10
  priority = 0 # corrected from 'prio'
  parent   = "vtnet1" 
  description = "Kubernetes Cluster VLAN"
}

# Interface Assignment is not currently supported by browningluke/opnsense provider 0.11.0
# User must manually assign "vlan0.10" to an interface (e.g. OPT1) in OPNsense GUI.
# resource "opnsense_interfaces_assignment" "kube_interface" {
#   device      = opnsense_interfaces_vlan.kube_vlan.device
#   description = "KUBE_NET"
# }

# Setup DHCP for the new Interface
# resource "opnsense_dhcp_server" "kube_dhcp" {
#   interface = opnsense_interfaces_assignment.kube_interface.id
#   ...
# }

# Example: DHCP Static Map (Uncomment when you have MAC addresses)
# resource "opnsense_dhcp_static_map" "control_plane_1" {
#   interface = opnsense_interfaces_assignment.kube_interface.id
#   mac       = "00:00:00:00:00:01"
#   ipaddr    = "192.168.10.11"
#   hostname  = "cp-01"
# }
