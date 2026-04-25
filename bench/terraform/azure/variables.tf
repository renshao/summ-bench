variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Short prefix for resource names. Lowercase letters/numbers/hyphens."
  type        = string
  default     = "regbench"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}$", var.prefix))
    error_message = "prefix must be 2-13 chars, start with a letter, lowercase letters/digits/hyphens only."
  }
}

variable "vm_size_registry" {
  description = "VM SKU for the registry server. Default Ddsv5 has 300 GB local NVMe and is broadly pre-quota'd. Use Lsv3 (1.92 TB NVMe) only if you've requested quota for it."
  type        = string
  default     = "Standard_D8ds_v5"
}

variable "vm_size_loadtester" {
  description = "VM SKU for the load tester. Default D2ds_v5 (2 vCPU / 8 GiB / 75 GiB NVMe) is plenty for HTTP-bound load gen; cargo build is ~5-7 min one-time. Same DDsv5 family as the registry, so no new quota needed."
  type        = string
  default     = "Standard_D2ds_v5"
}

variable "operator_cidr" {
  description = "CIDR allowed to SSH into the VMs (your home/office IP/32). Use curl ifconfig.me to find it."
  type        = string
}

variable "admin_username" {
  description = "Linux admin username on both VMs."
  type        = string
  default     = "azureuser"
}

variable "ssh_key_path" {
  description = "Path where the generated SSH private key is written locally."
  type        = string
  default     = "~/.ssh/registry-bench"
}
