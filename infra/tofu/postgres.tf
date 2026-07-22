# Azure Database for PostgreSQL — Flexible Server (managed). ONE server per
# workspace, so prod and staging never share a database. Public endpoint,
# TLS-only, firewalled to the VM's static IP — no VNet integration (no delegated
# subnet / private DNS zone). See README "Postgres".
#
# The admin password is generated here and exists ONLY in (encrypted) state.
# Read the ready-to-paste connection string with:
#   tofu output -raw pg_database_url
# then put it in the host's /srv/antgrid/.env as PG_DATABASE_URL.

resource "random_password" "pg" {
  length  = 32
  special = true
  # Unreserved URI chars only → the password needs no percent-encoding when
  # interpolated into PG_DATABASE_URL.
  override_special = "-_.~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
}

resource "azurerm_postgresql_flexible_server" "main" {
  # FQDN <name>.postgres.database.azure.com is globally unique — override
  # var.* or rename if antgrid-<env>-pg ever collides.
  name                = "${local.name_prefix}-pg"
  resource_group_name = azurerm_resource_group.main.name
  location            = local.location
  version             = "16"

  sku_name   = local.pg_sku
  storage_mb = 32768 # 32 GiB (minimum tier); grow with -var or in the portal.

  administrator_login    = "antgrid"
  administrator_password = random_password.pg.result

  # Public endpoint; access is gated by the firewall rule below. Leaving VNet
  # integration off keeps the network surface to a single allow-listed IP.
  public_network_access_enabled = true

  # Built-in automated backups (point-in-time restore) — the safety net that
  # makes prevent_destroy + a single server acceptable. Geo-redundancy off (cost).
  backup_retention_days        = 14
  geo_redundant_backup_enabled = false

  lifecycle {
    prevent_destroy = true   # blocks `tofu destroy` AND destroy-during-replace
    ignore_changes  = [zone] # Azure may pin an availability zone; don't fight it
  }
}

# Azure Flexible Server blocks `CREATE EXTENSION` unless the extension is named in
# the `azure.extensions` server parameter. The web schema's init migration creates
# pgcrypto + citext, so allow-list them here. This is a dynamic parameter (applied
# without a server restart). Keep in sync with extensions used by web/prisma.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "PGCRYPTO,CITEXT"
}

# Application database. The Flexible Server also ships a default `postgres` db;
# the app uses this one.
resource "azurerm_postgresql_flexible_server_database" "antgrid" {
  name      = "antgrid"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# Allow ONLY the VM's static public IP. A Standard-SKU public IP attached to the
# NIC is also the VM's outbound source IP, so this single address is exactly what
# Postgres sees. No "allow all Azure services" rule (that would be a broad open).
resource "azurerm_postgresql_flexible_server_firewall_rule" "vm" {
  name             = "allow-vm"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = azurerm_public_ip.main.ip_address
  end_ip_address   = azurerm_public_ip.main.ip_address
}
