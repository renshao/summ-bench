variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
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

variable "instance_type_registry" {
  description = "EC2 instance type for the registry server. Must have local NVMe instance store. m6id.2xlarge (8 vCPU / 32 GiB / 474 GB NVMe) matches Azure Standard_D8ds_v5 used in the Azure run."
  type        = string
  default     = "m6id.2xlarge"
}

variable "instance_type_loadtester" {
  description = "EC2 instance type for the load tester. Network/CPU-bound; no local storage needed."
  type        = string
  default     = "c6i.large"
}

variable "operator_cidr" {
  description = "CIDR allowed to SSH into the VMs (your IP/32). Use: curl -s ifconfig.me"
  type        = string
}

variable "admin_username" {
  description = "Linux admin username. Must match the Ubuntu AMI default user."
  type        = string
  default     = "ubuntu"
}

variable "ssh_key_path" {
  description = "Path where the generated SSH private key is written locally."
  type        = string
  default     = "~/.ssh/registry-bench-aws"
}
