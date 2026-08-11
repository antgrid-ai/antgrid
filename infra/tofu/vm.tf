resource "azurerm_linux_virtual_machine" "main" {
  name                = "${local.name_prefix}-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = local.vm_size
  computer_name       = "antgrid-${local.environment}"
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.main.id]

  # SSH-key auth only (no password). One block per authorized key (e.g. your
  # local key + the CI deploy key). NB: Azure treats provisioning keys as
  # immutable — changing this set replaces the VM (tofu shows -/+), so set every
  # key you need before the first real apply.
  dynamic "admin_ssh_key" {
    for_each = toset(var.ssh_public_keys)
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  # cloud-init: install Docker, create the shared edge network + deploy dir.
  # App images/files arrive later via the CI deploy workflow; secrets arrive via
  # a one-time scp of /srv/antgrid/.env.
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_username = var.admin_username
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init executes once, at first boot, so editing the template cannot
  # change a running host. Azure still treats custom_data as immutable, so
  # without this tofu offers to destroy and recreate the VM to "apply" a change
  # that would have no effect — taking /srv/antgrid/.env, which exists nowhere
  # else, and handing the rebuilt host the committed key list (see
  # ssh_keys.auto.tfvars) rather than the key CI actually holds.
  # To land a template change for real, replace the VM deliberately:
  #   tofu apply -replace=azurerm_linux_virtual_machine.main
  # and re-do the one-time .env upload afterwards.
  lifecycle {
    ignore_changes = [custom_data]
  }
}
