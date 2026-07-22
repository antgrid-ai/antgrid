# ─────────────────────────────────────────────────────────────────────────────
# Antgrid production infrastructure (OpenTofu).
#
# Provisions ONE Linux VM with Docker. The relay + web run on it via
# docker-compose (blue-green) — see deploy/. This is the only cloud-specific
# layer; the deploy/ rollout layer is cloud-agnostic and does not change.
#
# To move clouds, swap the azurerm resources in network.tf / vm.tf / dns.tf for
# the new provider's equivalents so outputs.tf still yields { public_ip,
# ssh_user, dns_instructions }. App secrets live in the host /srv/antgrid/.env —
# the ONE exception is the generated Postgres admin password (postgres.tf), which
# lives in state. That is why state encryption (below) is enforced.
#
# State lives in Azure Blob (azurerm backend). NOT a SaaS — just a storage
# container. Configure it once via backend.hcl (see backend.hcl.example) and
# `tofu init -backend-config=backend.hcl`.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend: connection details supplied at `tofu init` time via
  # -backend-config (file or flags) so nothing secret is committed.
  backend "azurerm" {}

  # ── State & plan encryption (OpenTofu native, fail-closed) ──────────────────
  # postgres.tf puts the generated DB admin password in state, so state must be
  # encrypted at rest. The structure below ENFORCES it; the passphrase is NOT
  # committed — it's supplied at runtime via the TF_ENCRYPTION env var, which
  # OpenTofu merges with this block. Export the SAME 32+ char passphrase locally
  # and in CI (store it as a CI secret):
  #
  #   export TF_ENCRYPTION='key_provider "pbkdf2" "state" { passphrase = "<32+ chars>" }'
  #
  # With enforced = true, OpenTofu refuses to read/write plaintext state, so a
  # missing/empty passphrase fails closed instead of silently writing cleartext.
  encryption {
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id comes from ARM_SUBSCRIPTION_ID; auth via az login locally or
  # OIDC (ARM_USE_OIDC / azure/login) in CI.
}
