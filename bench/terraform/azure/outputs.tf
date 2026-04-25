output "registry_public_ip" {
  value = azurerm_public_ip.registry.ip_address
}

output "registry_private_ip" {
  value = azurerm_network_interface.registry.private_ip_address
}

output "loadtester_public_ip" {
  value = azurerm_public_ip.loadtester.ip_address
}

output "loadtester_private_ip" {
  value = azurerm_network_interface.loadtester.private_ip_address
}

output "admin_username" {
  value = var.admin_username
}

output "ssh_private_key_path" {
  value = pathexpand(var.ssh_key_path)
}

output "storage_account_name" {
  value = azurerm_storage_account.bench.name
}

output "storage_account_key" {
  value     = azurerm_storage_account.bench.primary_access_key
  sensitive = true
}

output "registry_blob_container" {
  value = azurerm_storage_container.registry_blobs.name
}

output "reports_blob_container" {
  value = azurerm_storage_container.bench_reports.name
}

output "reports_sas_url" {
  value     = "https://${azurerm_storage_account.bench.name}.blob.core.windows.net/${azurerm_storage_container.bench_reports.name}?${data.azurerm_storage_account_sas.reports.sas}"
  sensitive = true
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "location" {
  value = azurerm_resource_group.rg.location
}
