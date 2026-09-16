# Rust dependency inventory

[`third-party-inventory.json`](third-party-inventory.json) records resolved
package names, versions, declared SPDX license expressions, declared license-file
paths, registry sources and direct-dependency status from `cargo metadata
--locked --format-version 1`. It includes build/dev and platform-specific
dependencies in the service graph. The recorded SHA-256 binds it to Cargo.lock.

The separate test-only `compat-client/Cargo.lock` is outside that production
graph and is not distributed with the service binary. Its upstream relay/base/DNS
pins are 1.0.0 and its declarations remain available through its own metadata.

This inventory is not complete redistribution validation. Final release images
must collect the applicable source license texts and NOTICE files, review any
missing/ambiguous declarations and include the required notices for the actual
compiled artifact. Regenerate and review this inventory after lockfile changes.
