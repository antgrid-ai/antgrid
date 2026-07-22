# SSH public keys authorized on the VM admin user — COMMITTED ON PURPOSE.
#
# Public keys are not secret, so they live in git (reviewable in diffs) instead
# of a CI variable. OpenTofu auto-loads any *.auto.tfvars locally AND in CI, so
# this is the single source of truth for both — no TF_VAR / repo-variable wiring.
#
# Install EVERY key you need before the first apply: changing this set after the
# VM exists is ForceNew (replaces the VM — Azure treats provisioning keys as
# immutable). The CI key's matching PRIVATE half is deploy.yml's SSH_PRIVATE_KEY
# secret (per GitHub Environment); your local private key stays on your laptop.
ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQGJQs9Qy8fo8WqG18yKoL390uEDRYIFwgnv3iTk+aB antgrid-vm",        # local (~/.ssh/antgrid_vm)
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEDQOlhrdqWS5S/oTBixNPkbFMII6tFv1u+VI5UazZRJ ci@antgrid-deploy", # CI deploy key (~/.ssh/antgrid_ci)
]
