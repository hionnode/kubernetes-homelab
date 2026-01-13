provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true
}

provider "opnsense" {
  uri            = var.opnsense_uri
  api_key        = var.opnsense_api_key
  api_secret     = var.opnsense_api_secret
  allow_insecure = true
}

provider "talos" {
  # Configuration usually handled via generated client config or defaulting to local ~/.talos/config
}
