terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  # Skip the slow per-subscription RP registration probe (azurerm 4.x default).
  # The RPs we need (Microsoft.Compute, Network, Storage) are registered on any
  # subscription that has ever held a VM. If apply fails with an unregistered RP
  # error, run: az provider register --namespace Microsoft.<Name>
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix          = random_string.suffix.result
  resource_prefix = "${var.prefix}-${local.suffix}"
  storage_name    = lower(replace("${var.prefix}bench${local.suffix}", "-", ""))
  tags = {
    project = "container-registry-bench"
    run_id  = local.suffix
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "${local.resource_prefix}-rg"
  location = var.location
  tags     = local.tags
}
