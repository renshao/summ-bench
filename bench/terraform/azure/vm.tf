resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = pathexpand(var.ssh_key_path)
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  content         = tls_private_key.ssh.public_key_openssh
  filename        = "${pathexpand(var.ssh_key_path)}.pub"
  file_permission = "0644"
}

resource "azurerm_linux_virtual_machine" "registry" {
  name                            = "${local.resource_prefix}-registry"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = var.vm_size_registry
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.registry.id]
  proximity_placement_group_id    = azurerm_proximity_placement_group.ppg.id
  disable_password_authentication = true
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    name                 = "${local.resource_prefix}-registry-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "loadtester" {
  name                            = "${local.resource_prefix}-loadtester"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = var.vm_size_loadtester
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.loadtester.id]
  proximity_placement_group_id    = azurerm_proximity_placement_group.ppg.id
  disable_password_authentication = true
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    name                 = "${local.resource_prefix}-loadtester-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
