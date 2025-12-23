terraform {
  required_version = ">= 1.10.0"

  backend "s3"{
    key = "proxmox/terraform.tfstate"
    use_lockfile = true
}

  required_providers {
     proxmox = {
    source = "bpg/proxmox"
    version = "~> 0.70.0"
}
}
  
  
}
