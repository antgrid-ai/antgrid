#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time bootstrap for the OpenTofu infra (infra/tofu) + its CI.
#
# Idempotent. Creates the two things tofu can't create for itself:
#   1. The Azure Blob container that holds OpenTofu state.
#   2. An Azure AD app + federated credentials so GitHub Actions authenticates
#      to Azure via OIDC (no stored client secret), with Contributor on the sub.
#
# Then (if `gh` is installed + authenticated) it sets the repo secrets/vars the
# infra.yml workflow needs. Otherwise it prints them for you to set by hand.
#
# Requires: az (logged in), and optionally gh. Re-runnable safely.
#
# Usage:
#   az login
#   GITHUB_REPO=Radha-AI-Products/antgrid ./bootstrap.sh
#
# Override any default via env var (see the block below).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config (override via env) ────────────────────────────────────────────────
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="${LOCATION:-eastus}"
TFSTATE_RG="${TFSTATE_RG:-antgrid-tfstate}"
TFSTATE_SA="${TFSTATE_SA:-antgridtfstate}"      # 3-24 lowercase alphanumerics, GLOBALLY unique
TFSTATE_CONTAINER="${TFSTATE_CONTAINER:-tfstate}"
APP_NAME="${APP_NAME:-antgrid-infra-ci}"
GITHUB_REPO="${GITHUB_REPO:-}"                  # owner/repo — required for federated creds + gh wiring
# Default branch + that PRs target. Federated creds are scoped to these.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

if [[ -z "$GITHUB_REPO" ]]; then
  GITHUB_REPO="Radha-AI-Products/antgrid"
fi

ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID="$(az account show --query tenantId -o tsv)"

# ── 1. State backend: RG + storage account + container ───────────────────────
say "State backend: resource group '$TFSTATE_RG'"
az group create -n "$TFSTATE_RG" -l "$LOCATION" -o none

say "State backend: storage account '$TFSTATE_SA'"
if ! az storage account show -n "$TFSTATE_SA" -g "$TFSTATE_RG" -o none 2>/dev/null; then
  az storage account create -n "$TFSTATE_SA" -g "$TFSTATE_RG" -l "$LOCATION" \
    --sku Standard_LRS --min-tls-version TLS1_2 \
    --allow-blob-public-access false -o none
fi

say "State backend: container '$TFSTATE_CONTAINER'"
az storage container create -n "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_SA" --auth-mode login -o none

# ── 2. Azure AD app + OIDC federated credentials + role ──────────────────────
say "AD app: '$APP_NAME'"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
fi
echo "    appId (AZURE_CLIENT_ID) = $APP_ID"

# Service principal for the app (idempotent).
if ! az ad sp show --id "$APP_ID" -o none 2>/dev/null; then
  az ad sp create --id "$APP_ID" -o none
fi
SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv)"

# Federated credentials: one per GitHub OIDC subject the workflow uses.
#   - pull_request           : the plan-on-PR job
#   - ref:refs/heads/<branch>: workflow_dispatch on the default branch (apply)
add_fic() {
  local name="$1" subject="$2"
  if az ad app federated-credential list --id "$APP_ID" \
       --query "[?subject=='$subject'] | [0].id" -o tsv | grep -q .; then
    echo "    federated cred '$name' already exists"
    return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$name\",
    \"issuer\": \"$ISSUER\",
    \"subject\": \"$subject\",
    \"audiences\": [\"$AUDIENCE\"]
  }" -o none
  echo "    federated cred '$name' created"
}
say "OIDC federated credentials for $GITHUB_REPO"
add_fic "gh-pull-request" "repo:${GITHUB_REPO}:pull_request"
add_fic "gh-default-branch" "repo:${GITHUB_REPO}:ref:refs/heads/${DEFAULT_BRANCH}"

say "Role assignment: Contributor on subscription"
# NOTE: `az role assignment list/create` mis-routes to a tenant-level request on
# some CLI versions (seen on 2.87.0: "MissingSubscription"). The raw ARM REST API
# works regardless, so we drive role assignments through `az rest`.
CONTRIBUTOR="b24988ac-6180-42a0-ab88-20f7382dd24c"   # well-known Contributor role-definition id
SCOPE="/subscriptions/$SUBSCRIPTION_ID"
ROLE_DEF="$SCOPE/providers/Microsoft.Authorization/roleDefinitions/$CONTRIBUTOR"

gen_guid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  elif command -v python >/dev/null 2>&1; then python -c "import uuid;print(uuid.uuid4())"
  else powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString()" | tr -d '\r\n'
  fi
}

existing="$(az rest --method get \
  --url "https://management.azure.com$SCOPE/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$SP_OBJECT_ID'" \
  --query "value[?properties.roleDefinitionId=='$ROLE_DEF'] | length(@)" -o tsv 2>/dev/null || echo 0)"

if [[ "${existing:-0}" == "0" ]]; then
  body="$(mktemp)"
  cat > "$body" <<JSON
{ "properties": { "roleDefinitionId": "$ROLE_DEF", "principalId": "$SP_OBJECT_ID", "principalType": "ServicePrincipal" } }
JSON
  # A freshly-created SP can lag in AAD replication — retry the PUT a few times.
  assigned=false
  for attempt in 1 2 3 4 5; do
    if az rest --method put \
         --url "https://management.azure.com$SCOPE/providers/Microsoft.Authorization/roleAssignments/$(gen_guid)?api-version=2022-04-01" \
         --body "@$body" -o none 2>/dev/null; then
      echo "    Contributor assigned"
      assigned=true
      break
    fi
    echo "    role assignment not ready (attempt $attempt) — SP may still be propagating; retrying"
    sleep 10
  done
  rm -f "$body"
  # Don't print "✅ complete" with the SP missing its role — that surfaces later
  # as an opaque OpenTofu auth failure. Fail here instead.
  if [[ "$assigned" != true ]]; then
    echo "ERROR: Contributor role assignment failed after 5 attempts (SP $SP_OBJECT_ID)." >&2
    echo "       SP may still be propagating in AAD — re-run this script in a minute." >&2
    exit 1
  fi
else
  echo "    Contributor already assigned"
fi

# ── 3. Wire the GitHub repo (secrets + vars) ─────────────────────────────────
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  say "Setting GitHub secrets + variables on $GITHUB_REPO via gh"
  gh secret set AZURE_CLIENT_ID       -R "$GITHUB_REPO" -b "$APP_ID"
  gh secret set AZURE_TENANT_ID       -R "$GITHUB_REPO" -b "$TENANT_ID"
  gh secret set AZURE_SUBSCRIPTION_ID -R "$GITHUB_REPO" -b "$SUBSCRIPTION_ID"
  gh variable set TFSTATE_RG          -R "$GITHUB_REPO" -b "$TFSTATE_RG"
  gh variable set TFSTATE_SA          -R "$GITHUB_REPO" -b "$TFSTATE_SA"
  gh variable set TFSTATE_CONTAINER   -R "$GITHUB_REPO" -b "$TFSTATE_CONTAINER"

  # State-encryption passphrase (infra.yml's TF_ENCRYPTION). This MUST stay
  # stable forever — regenerating it orphans all existing encrypted state. So:
  # use $STATE_PASSPHRASE if given, else keep an existing secret, else generate
  # one ONCE and print it (gh can't read a secret back).
  if [[ -n "${STATE_PASSPHRASE:-}" ]]; then
    gh secret set TF_STATE_PASSPHRASE -R "$GITHUB_REPO" -b "$STATE_PASSPHRASE"
    echo "    TF_STATE_PASSPHRASE set from \$STATE_PASSPHRASE."
  elif gh secret list -R "$GITHUB_REPO" | grep -q '^TF_STATE_PASSPHRASE'; then
    echo "    TF_STATE_PASSPHRASE already set — left as-is (regenerating would orphan state)."
  else
    STATE_PASSPHRASE="$(openssl rand -base64 32)"
    gh secret set TF_STATE_PASSPHRASE -R "$GITHUB_REPO" -b "$STATE_PASSPHRASE"
    echo ""
    echo "    *** GENERATED TF_STATE_PASSPHRASE — SAVE THIS NOW (shown only once) ***"
    echo "      $STATE_PASSPHRASE"
    echo "    Export it for local tofu runs (same value, every time):"
    echo "      export TF_ENCRYPTION='key_provider \"pbkdf2\" \"state\" { passphrase = \"$STATE_PASSPHRASE\" }'"
    echo ""
  fi
  echo "    done. (Authorized SSH public keys are committed in infra/tofu/ssh_keys.auto.tfvars — no repo variable needed.) Still set manually: deploy.yml's SSH_HOST/SSH_USER/SSH_PRIVATE_KEY."
else
  cat <<EOF

gh not available/authenticated — set these yourself in the repo settings:

  Secrets (Settings → Secrets and variables → Actions → Secrets):
    AZURE_CLIENT_ID        = $APP_ID
    AZURE_TENANT_ID        = $TENANT_ID
    AZURE_SUBSCRIPTION_ID  = $SUBSCRIPTION_ID
    TF_STATE_PASSPHRASE    = <32+ char passphrase; generate once and REUSE forever
                              — regenerating orphans encrypted state. Also export
                              it locally as TF_ENCRYPTION (see infra/tofu README).>

  Variables (… → Variables):
    TFSTATE_RG             = $TFSTATE_RG
    TFSTATE_SA             = $TFSTATE_SA
    TFSTATE_CONTAINER      = $TFSTATE_CONTAINER

  (Authorized SSH public keys are committed in infra/tofu/ssh_keys.auto.tfvars —
   no repo variable needed.)
EOF
fi

# ── 4. Local backend.hcl for `tofu init` ─────────────────────────────────────
BACKEND_HCL="$(cd "$(dirname "$0")/../tofu" && pwd)/backend.hcl"
say "Writing $BACKEND_HCL"
cat > "$BACKEND_HCL" <<EOF
resource_group_name  = "$TFSTATE_RG"
storage_account_name = "$TFSTATE_SA"
container_name       = "$TFSTATE_CONTAINER"
key                  = "antgrid.tfstate"
EOF

cat <<EOF

✅ Bootstrap complete.

Next:
  cd ../tofu
  export ARM_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
  tofu init -backend-config=backend.hcl
  # Authorized SSH keys are already committed in ssh_keys.auto.tfvars — edit it
  # to change the set. terraform.tfvars is only needed for optional overrides.
  tofu apply

CI: the infra.yml workflow now authenticates via OIDC — no secrets rotation needed.
EOF
