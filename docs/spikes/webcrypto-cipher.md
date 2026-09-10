# Spike: BoringSSL for the E2E transport cipher on Windows/Linux

Status: **spike, and it MUST NOT MERGE as it stands.** The cipher works and is
fast, but the dependency alone breaks `flutter build windows` on any machine
without NASM — the default-off dart-define does not gate that, because merely
depending on the package registers its plugin. See "The Windows build fails"
below.

## Why

`installNativeE2eCipher` (`app/lib/config/native_crypto.dart`) installs
`FlutterAesGcm`, which reaches OS crypto only on Android, iOS and macOS.
`cryptography_flutter` declares no Windows or Linux plugin, so on desktop every
relay frame is opened by a pure Dart AES-GCM — a `compute` isolate past its size
threshold, the UI isolate below it. The handshake primitives are not in scope
and are not swappable (see `docs/protocol/e2e-handshake.md` §7).

`package:webcrypto` (Google, Apache-2.0) bundles BoringSSL over `dart:ffi` and
builds for both platforms.

## What the numbers say

Decrypt throughput, `flutter test` on the CI Linux container.
**JIT, not AOT** — a release build runs the Dart cipher considerably faster, so
read the ratios as an upper bound, not a shipping figure.

| Payload | Pure Dart | `FlutterAesGcm` (today) | BoringSSL |
|---|---|---|---|
| 256 B control frame | 3.7 MB/s | 6.4 MB/s | 7.8 MB/s |
| 64 KB tree/diff | 10.9 MB/s | 9.2 MB/s | **479 MB/s** |
| 2 MB preview asset | 10.9 MB/s | 9.9 MB/s | **168 MB/s** |

The 2 MB figure is allocation-noisy — repeated runs ranged 100–257 MB/s — because
the adapter copies the payload twice to satisfy the `SecretBox` shape. The 64 KB
figure is stable across runs.

**A BoringSSL call costs a flat ~24 µs regardless of size** (FFI hop, key-cache
probe, buffer copies) while the Dart cipher's cost is all throughput. Measured
per-op crossover:

| Payload | 256 B | 512 B | 1 KB | 4 KB | 8 KB | 16 KB |
|---|---|---|---|---|---|---|
| Speedup vs pure Dart | 0.53x | 0.96x | 2.97x | 15.1x | 28.5x | 46.8x |

Below ~512 bytes BoringSSL is a **regression**, so `WebcryptoAesGcm` delegates to
the Dart cipher under `defaultMinBytesWorthFfi`. Reproduce with
`cd app && flutter test test/config/webcrypto_bench.dart`.

## What was built

- `app/lib/config/webcrypto_aes_gcm.dart` — `WebcryptoAesGcm extends AesGcm`,
  the shape `E2eTransportDart.useAlgorithm` accepts. Splits Web Crypto's
  combined `ciphertext ‖ tag` into `SecretBox`, caches imported keys, translates
  BoringSSL's `OperationError` into `SecretBoxAuthenticationError`.
- `app/lib/config/native_crypto.dart` — selects it only when
  `--dart-define=WEBCRYPTO_E2E_CIPHER=true` **and** the target is Windows or
  Linux. Every other platform keeps `FlutterAesGcm` untouched.
- `app/test/config/webcrypto_aes_gcm_test.dart` — runs BoringSSL against the
  same `evals/fixtures/e2e-handshake-vectors.json` golden frames that
  `packages/antgrid_relay_client/test/e2e_vectors_test.dart` and
  `evals/tests/gate-vectors.test.ts` pin, so a cipher that passes here is
  byte-compatible with what the bridge seals.

## Three things that bit, and would bite again

**Key import is not free and the transport is stateless.** `E2eTransportDart`
constructs per frame by design, so a naive adapter imports a key on every frame.
Import measured ~15 µs against a ~24 µs small-frame decrypt — it was most of the
cost. Hence the cache.

**The cache must copy the key bytes.** `SessionKeys.zeroize` fills the caller's
buffer with zeros *in place*. An entry holding that reference silently becomes an
all-zero key and would then answer a later lookup for a genuinely all-zero key
with the wrong BoringSSL handle. Pinned by a test.

**BoringSSL signals a bad tag with `OperationError`, which extends `Error`.**
`E2eTransportDart.open` catches broadly so it is safe today, but anything
narrowing that to `on Exception` turns a tampered frame from a dropped frame
into a crash. The adapter translates at the boundary rather than relying on the
catch.

## The tradeoff this makes, which is not only speed

Today's `FlutterAesGcm` moves large payloads **off the UI isolate** onto a
`compute` isolate. `WebcryptoAesGcm` does not — BoringSSL runs on the calling
isolate, which is the UI isolate.

So a 2 MB preview asset goes from roughly 200 ms of crypto that does not block
the UI, to roughly 12 ms that does. That is the right trade for one asset: 12 ms
of stall beats 200 ms of latency. It is a worse trade for a preview page pulling
many large assets back to back, where those 12 ms slices land on the UI isolate
one after another. If that shows up in practice, the answer is not to revert —
it is BoringSSL *inside* a background isolate, which nothing here does yet.

## The Windows build fails: BoringSSL needs NASM

Measured, not predicted — a cold `flutter build windows` on Windows 11 with no
`app/build/` present:

```
CMake Error at flutter/ephemeral/.plugin_symlinks/webcrypto/windows/CMakeLists.txt:14 (enable_language):
  No CMAKE_ASM_NASM_COMPILER could be found.
```

`enable_language(ASM_NASM)` is unconditional and runs *before* the block thirty
lines below it that would otherwise degrade to `-DOPENSSL_NO_ASM` when a target
has no assembly sources. The graceful path exists and is unreachable. So
**NASM becomes a hard toolchain prerequisite** — for every contributor building
the Windows app, and for the CI and release runners — bought for a cipher that
is a performance optimization. That is the cost to weigh, not the CMake error.

**The dart-define does not gate this.** That build ran with
`WEBCRYPTO_E2E_CIPHER` unset, which is how the failure was found: the Flutter
tool registers every dependency that declares a Windows platform into
`generated_plugins.cmake`, so the plugin's CMake runs whether or not a single
Dart symbol references it. A flag can keep a cipher out of the transport; it
cannot keep a plugin out of the build.

It also **poisons `app/build/` exactly as the root `CLAUDE.md` gotcha
describes**, now confirmed rather than feared: after the failed configure,
`app/build/windows/x64/CMakeCache.txt` carried
`CMAKE_INSTALL_PREFIX:PATH=C:/Program Files/antgrid`, and no later successful
configure corrects it. Recovery is `Remove-Item -Recurse -Force app\build\windows`.

Given this, the Win32 CNG route sketched in the original comparison deserves a
second look before anyone installs NASM everywhere: `bcrypt.dll` ships with
Windows, needs no build step and no prerequisite, and the binding surface is
about five functions. It buys less than BoringSSL (Windows only, nothing for
Linux) at a far lower toolchain cost.

## Open before this can ship

1. **NASM everywhere, or a different cipher on Windows.** See above. Unblocking
   the build means adding NASM to `DEVELOPMENT.md`'s prerequisites and to the
   Windows CI and release runners. Not attempted here — the finding is the
   decision, and it is not the spike's to make.
2. **CI build cost is only half measured.** The host-test build the new CI step
   adds (`flutter pub run webcrypto:setup`, needed because `flutter test` runs
   on the host VM and never registers the plugin) takes **~16 s cold** on the
   CI container, and `ci-android.yml` caches nothing, so that is ~16 s on every
   run. Cheap. The *app* build is the unmeasured one: Windows does not get far
   enough to measure (above), and no Linux runner has built the plugin yet.
3. **Key material outlives `zeroize`.** The cache holds imported keys inside
   BoringSSL, where `SessionKeys.zeroize` cannot reach. Bounded to four entries,
   and `WebcryptoAesGcm.evictImportedKeys()` exists, but nothing calls it — wire
   it to session teardown before shipping.
4. **The `SecretBox` round trip wastes two copies of every large payload.** The
   transport splits `nonce ‖ ct ‖ tag` apart, the adapter joins it back. Handing
   the cipher the whole frame would need a wider seam than `AesGcm` on the Apache
   side; worth it only if the preview path is the motivating workload.
5. **Not measured on Windows.** Every number here is Linux. AES-NI is the same
   instruction, but the plugin, the build and the threshold are not.
6. **`THIRD-PARTY.md`** needs a BoringSSL entry once this ships.
