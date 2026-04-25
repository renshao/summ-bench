resource "azurerm_storage_account" "bench" {
  name                          = local.storage_name
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  account_kind                  = "StorageV2"
  access_tier                   = "Hot"
  shared_access_key_enabled     = true
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_storage_container" "registry_blobs" {
  name                  = "registry-blobs"
  storage_account_id    = azurerm_storage_account.bench.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "bench_reports" {
  name                  = "bench-reports"
  storage_account_id    = azurerm_storage_account.bench.id
  container_access_type = "private"
}

data "azurerm_storage_account_sas" "reports" {
  connection_string = azurerm_storage_account.bench.primary_connection_string
  https_only        = true

  resource_types {
    service   = false
    container = true
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  start  = timestamp()
  expiry = timeadd(timestamp(), "24h")

  permissions {
    read    = true
    write   = true
    delete  = false
    list    = true
    add     = true
    create  = true
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}
