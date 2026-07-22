variable "location" {
  description = "Override the per-environment Azure region. null = env default (see locals.tf env_defaults). NB: this subscription rejects VM creation in eastus/eastus2/westeurope."
  type        = string
  default     = null
}

variable "vm_size" {
  description = "Override the per-environment VM size (sized for two colors running concurrently during a flip). null = env default (see locals.tf env_defaults)."
  type        = string
  default     = null
}

variable "pg_sku" {
  description = "Override the per-environment Postgres Flexible Server SKU. null = env default (see locals.tf env_defaults). Scale up e.g. to GP_Standard_D2ds_v5 on evidence."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "Linux admin user (also the SSH/deploy user)."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized on the VM admin user. Provide one or more — e.g. your local key AND the CI deploy key — so both can log in. Set in the committed ssh_keys.auto.tfvars (auto-loaded locally + in CI; public keys aren't secret). The CI key's matching private half is deploy.yml's SSH_PRIVATE_KEY secret."
  type        = list(string)
  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one SSH public key."
  }
}

variable "domain" {
  description = "Override the per-environment domain. app.<domain> -> web, relay.<domain> -> relay. null = env default (see locals.tf env_defaults)."
  type        = string
  default     = null
}

variable "manage_dns" {
  description = "If true, manage an Azure DNS zone + A records. If false, outputs tell you which A records to create at your registrar."
  type        = bool
  default     = false
}
