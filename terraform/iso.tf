resource "proxmox_virtual_environment_download_file" "opnsense_iso" {
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = var.proxmox_node
  url                     = var.opnsense_iso_url
  file_name               = "opnsense-25.7.iso"
  decompression_algorithm = "bz2"

  # Optional: Decompress if bz2 (Proxmox generally handles standard ISOs,
  # but opnsense comes as .bz2. The provider might handle this or PVE does.
  # If issues arise, we might need a separate step or uncompressed URL,
  # but standard PVE download usually handles common compressions or just saves the file.
  # Note: PVE 7/8 download-url usually supports uncompression if detected.)
  # checking provider docs: decompresses automatically if detected usually.
}

resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node
  url          = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-amd64.iso"
}
