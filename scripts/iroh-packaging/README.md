# Iroh packaging integrity

`flutter-source-pins.json` is the reviewed baseline used by
`bun run scripts/check-iroh-packaging.ts` to verify the resolved Flutter packages,
FRB versions and upstream Rust manifest/lockfile. Do not regenerate these hashes
from build output to silence a mismatch.

`native-artifacts.json` preserves the signed Windows CLI artifact digest from
the historical prototype. It is not a digest of the source-built Flutter DLL
and does not qualify other platforms or final package signatures.

The prototype source and standalone dependency graphs were retired. Run the
production host and Dart checks listed in [qualification](../../docs/iroh-qualification.md).
