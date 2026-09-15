# Antgrid peer transport

ELv2, Flutter-free transport implementation shared by the app and standalone
qualification CLI. Apache `antgrid_relay_client` supplies the `PeerLink` contract
and E2E session machinery. Native transport never replaces application E2E or
host command authorization.

The embedding process supplies protected `EndpointKeyStore` storage,
device-authenticated enrollment HTTP requests, and an `AuthorizationLease`.
Create one `NativeEndpointOwner` per active enrollment with only the relay
origins in its authoritative snapshot. Close individual links during reconnect;
upstream FRB runtime disposal is process-final teardown only.

`PeerLinkSelector` supports WebSocket, Iroh preferred and evaluation-only Iroh
selection. E2E starts after selection. The app owns reconnect policy and must
refresh authorization on startup and resume. `LeasedPeerLink` applies the same
dispatch fence to upgraded WebSocket sessions.

Run these commands serially from this directory:

```text
dart analyze
dart test
dart run iroh_quic:setup
dart run bin/native_smoke.dart
dart compile exe bin/native_smoke.dart -o ../../.tmp/iroh-native-smoke.exe
```

Use the upstream signed setup process without disabling verification. The native
smoke uses synthetic admission to exercise the production record adapter and
its cleanup/rejection paths. It does not qualify account authorization or host
features. The app bundles native code through pinned upstream `iroh_flutter`;
that separate source build needs platform packaging qualification.

Current release limitations and security evidence are in
[the migration ledger](../../docs/iroh-migration-ledger.md) and
[upstream audit](../../docs/iroh-relay-upstream-audit.md). WebSocket remains the
production default. Unknown native close causes remain terminal until upstream
bindings provide a classification that cannot turn authorization rejection into
fallback.
