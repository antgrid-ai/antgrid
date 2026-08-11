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
# DRIFT since 2026-08-11 — this list does NOT describe the VMs. The CI entry
# below is a key whose private half was lost. The key CI actually authenticates
# with is:
#
#   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJgWCcFXodRwPKmLV1ySlbwJVQLNo3XjO8oCqb4DnPGf ci@antgrid-deploy
#
# installed straight into azureuser's authorized_keys on prod and staging, and
# verified against both. It is deliberately NOT added to the list: that is
# ForceNew, so every plan would then advertise a destroy-and-recreate of both
# VMs, and infra.yml posts plans onto PRs where one `apply` would take
# production with it — along with the host .env, which exists only on the VM.
#
# At the next real VM rebuild, swap the stale CI entry below for the key above.
# A rebuild already requires re-running bootstrap, so that is the moment this
# reconciles for free. Until then a rebuild silently drops CI's access, which is
# the failure this note exists to prevent.
ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQGJQs9Qy8fo8WqG18yKoL390uEDRYIFwgnv3iTk+aB antgrid-vm",        # local (~/.ssh/antgrid_vm)
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEDQOlhrdqWS5S/oTBixNPkbFMII6tFv1u+VI5UazZRJ ci@antgrid-deploy", # CI deploy key (~/.ssh/antgrid_ci)
]
