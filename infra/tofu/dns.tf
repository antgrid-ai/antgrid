# Optional: manage DNS in Azure. Off by default — most setups keep DNS at their
# existing registrar/Cloudflare and just create two A records (see outputs).
resource "azurerm_dns_zone" "main" {
  count               = var.manage_dns ? 1 : 0
  name                = local.domain
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_dns_a_record" "subdomains" {
  # errex is prod-only (one instance serves staging via a separate project), so
  # its record exists only in the prod environment. Gate on local.environment,
  # not the raw workspace, so the unused `default` workspace — which falls back
  # to prod config (see locals.tf) — also gets the record.
  for_each = var.manage_dns ? toset(concat(["app", "relay"], local.environment == "prod" ? ["errex"] : [])) : toset([])

  name                = each.key
  zone_name           = azurerm_dns_zone.main[0].name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.main.ip_address]
}
