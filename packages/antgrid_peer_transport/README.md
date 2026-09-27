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
```

Use the upstream signed setup process without disabling verification.

Cross-binding qualification — a real `IrohPeerLink` (this package, over
`iroh_quic`) against a real `NativeHostConnection` host (the bridge, over
`@number0/iroh`) — runs from the repository root, not from this directory:

```text
IROH_INTEROP_NATIVE_LIBRARY=<path> bun run --filter antgrid-evals test:evals:dart-client-e2e
IROH_INTEROP_NATIVE_LIBRARY=<path> bun run --filter antgrid-evals test:evals:peer-resume
```

`test:evals:dart-client-e2e` drives the production Dart relay/transport code
against a real bridge (project, file, terminal and managed-checkout traffic);
`test:evals:peer-resume` has the bridge close the Dart peer on a host resume and
checks it comes back on the same endpoint identity. Two paths are proved over
the TS binding only: the raw NOT_READY admission refusal
(`gate-stream-admission.test.ts`), because `MachineSession.openProject` sends
`project:start` first and so never reaches it, and the close on remote access
switched off, because the eval client reports no peer close of its own.
Set `IROH_INTEROP_NATIVE_LIBRARY` when the native library is not on
the default search path. The app bundles native code through pinned upstream
`iroh_flutter`; that separate source build needs platform packaging
qualification of its own.

Native release qualification remains incomplete. Unknown native close causes remain terminal until upstream
bindings provide a verified retry classification.
