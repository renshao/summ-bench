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
  description = "VM SKU for the registry server. Lsv3 family gives local NVMe (>= 200 GB)."
  type        = string
  default     = "Standard_L8s_v3"
}

variable "vm_size_loadtester" {
  description = "VM SKU for the load tester."
  type        = string
  default     = "Standard_D8s_v5"
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
