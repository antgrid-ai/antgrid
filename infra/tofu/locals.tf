# Environment is the selected OpenTofu workspace. Provision each environment with:
#   tofu workspace select -or-create prod     (or: staging)
#   tofu apply
# Each workspace keeps its own isolated state in the same Azure Blob backend, so
# `prod` and `staging` are fully independent VMs in the same subscription.
#
# The `default` workspace is unused but falls back to prod config so `plan`/
# `validate` work before a workspace is selected.
locals {
  environment = contains(["prod", "staging"], terraform.workspace) ? terraform.workspace : "prod"

  # Per-environment defaults — region, size, and domain all vary by env. Both run
  # the same blue-green stack (Caddy + 2x web + 2x relay = 5 containers;
  # Postgres is external), staging just smaller and on a staging.<domain> host.
  #
  # prod  = westus / D2as_v7 (2 vCPU / 8 GiB, AMD, *non-burstable*): dedicated
  #         CPU, no credit-throttle cliff. Moved off westus2: this subscription is
  #         offer-restricted from Postgres Flexible Server there
  #         (LocationIsOfferRestricted); westus offers both. NB: D2ds_v5 is capacity-
  #         restricted in westus on this sub — D2as_v7 is available (az vm list-skus).
  # staging = southeastasia / B2als_v2 (2 vCPU / 4 GiB, AMD, burstable v2): Basv2
  #         family has quota (65) in southeastasia; the only SKU restriction is
  #         zone 1, and we don't pin a zone, so it deploys. 4 GiB fits 5 containers.
  # (Sub rejects VM creation in eastus/eastus2/westeurope, and Postgres in westus2.)
  # See README "VM sizing".
  #
  # pg_sku is the Postgres Flexible Server size. B_Standard_B1ms (1 vCore / 2 GiB,
  # burstable) is the cheap floor — the web DB is low-traffic; scale on
  # evidence (see README "Postgres").
  env_defaults = {
    prod    = { location = "westus", vm_size = "Standard_D2as_v7", domain = "antgrid.ai", pg_sku = "B_Standard_B1ms" }
    staging = { location = "southeastasia", vm_size = "Standard_B2als_v2", domain = "staging.antgrid.ai", pg_sku = "B_Standard_B1ms" }
  }

  # Unique per-environment name prefix so prod + staging never collide.
  name_prefix = "antgrid-${local.environment}"

  # var.* (when set) override the per-environment default.
  location = coalesce(var.location, local.env_defaults[local.environment].location)
  vm_size  = coalesce(var.vm_size, local.env_defaults[local.environment].vm_size)
  domain   = coalesce(var.domain, local.env_defaults[local.environment].domain)
  pg_sku   = coalesce(var.pg_sku, local.env_defaults[local.environment].pg_sku)
}
