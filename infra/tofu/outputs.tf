output "environment" {
  description = "The environment this state provisions (= the selected workspace)."
  value       = local.environment
}

output "public_ip" {
  description = "Static public IP of the VM — use as SSH_HOST and the DNS A-record target."
  value       = azurerm_public_ip.main.ip_address
}

output "ssh_user" {
  description = "Admin/deploy user for SSH."
  value       = var.admin_username
}

output "ssh_connect" {
  description = "Ready-to-paste SSH command."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
}

output "pg_fqdn" {
  description = "Postgres Flexible Server hostname."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

# Ready-to-paste PG_DATABASE_URL for the host /srv/antgrid/.env. Holds the admin
# password, so it's sensitive — read it explicitly with:
#   tofu output -raw pg_database_url
output "pg_database_url" {
  description = "PG_DATABASE_URL for the host .env (sensitive)."
  # User and db name are read from the resources (not restated) so the URL can't
  # drift if either is ever parameterized. Port/sslmode are protocol constants.
  value     = "postgres://${azurerm_postgresql_flexible_server.main.administrator_login}:${random_password.pg.result}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.antgrid.name}?sslmode=require"
  sensitive = true
}

# When manage_dns = false, create these A records at your registrar.
# When true, delegate the domain's nameservers to the Azure DNS zone (see its NS records).
output "dns_instructions" {
  description = "What to do for DNS."
  value       = var.manage_dns ? "Azure DNS zone '${local.domain}' manages app/relay A records. Delegate the domain's nameservers to this zone (see the zone's NS records in the Azure portal)." : "Create these A records at your DNS provider:\n  app.${local.domain}   A  ${azurerm_public_ip.main.ip_address}\n  relay.${local.domain} A  ${azurerm_public_ip.main.ip_address}"
}
