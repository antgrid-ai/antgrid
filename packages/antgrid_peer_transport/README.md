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

`PeerConnectionAttempt` bounds a native dial, distinguishes cancellation from failure, and disposes late links. Unsettled native calls retain their slot, preventing retries from accumulating uncancellable work.
E2E starts after connection. The app owns reconnect policy and must refresh
authorization on startup and resume. `LeasedPeerLink` fences native dispatch.
Iroh handles direct and relayed connectivity; there is no WebSocket payload fallback.

Approved relay origins must be `https`. `isApprovedRelayOrigin` widens that to
`http` only when the binary was compiled with
`--dart-define=ANTGRID_DEV_INSECURE_RELAY=true`, for the cleartext local stack in
`aspire/README.md`, and only for a loopback or private host — an opted-in build
still refuses a public plaintext origin. It is a compile-time constant on
purpose: a release build
cannot be switched into it by a setting, an environment variable or anything an
authorization snapshot claims. `dart test` gates whichever build it runs, so
gate the opted-in one explicitly with
`dart --define=ANTGRID_DEV_INSECURE_RELAY=true test`.

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

`bin/interop_app.dart` is the app role of the cross-binding gate and is driven
by the bridge, never run directly:

```text
bun run --filter antgrid-bridge qualify:iroh-interop
```

It dials a real `NativeHostConnection` host binding `@number0/iroh` while this side
binds `iroh_quic`, so it is the only gate covering the pairing the product
actually ships. It also exercises three host-resume cycles with fresh native/E2E sessions and stable project bindings on the shared app endpoint.
Set `IROH_INTEROP_NATIVE_LIBRARY` when the library is not on the default search
path, and `IROH_INTEROP_DART` to choose the Dart executable. `IROH_SMOKE_LOG_LEVEL`
surfaces host logs, which are the only account of why a host dropped a peer.

Current release limitations and security evidence are in
[the migration ledger](../../docs/iroh-migration-ledger.md) and
[qualification](../../docs/iroh-qualification.md). Native release qualification
remains incomplete. Unknown native close causes remain terminal until upstream
bindings provide a verified retry classification.
