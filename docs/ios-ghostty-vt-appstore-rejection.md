# Bug: ghostty-vt.framework rejected by App Store validation

> Dated record. It describes the packages as they were vendored under
> `packages/`; they now resolve from a git fork, so every `packages/ghostty_vte/…`
> and `packages/portable_pty/…` path below lives in that repository instead — and
> the hook it describes has since been replaced by `native_prebuilt`, which reads
> none of the environment variables named here. See
> [dart-terminal-fork-release.md](dart-terminal-fork-release.md). The rejection
> itself is unchanged; the fix that ships is not — see Resolution.

## Resolution (supersedes "Recommended fix" below)
The static-link plan was never implemented. What shipped first was the *fallback*
— Zig compiles, Apple's `ld64` does the final link (`scripts/build-ghostty-ios.sh`,
commit `d04d1d79`), with `minos` lowered to 13.0 afterwards (`095b13a2`).

Since **`ghostty_vte-v0.1.4` none of that is necessary: upstream links the iOS
device asset with `ld64` itself.** Measured on the two published
`vte-ios-arm64.tar.gz` payloads:

| | v0.1.3 (rejected) | v0.1.4 |
|---|---|---|
| Mach-O build tool | `5` (Zig's own linker) | `LD` 1267.0 (ld64) |
| `LC_ENCRYPTION_INFO_64` | absent | present |
| fixups | `LC_DYLD_INFO_ONLY` | chained fixups + exports trie |
| `__LINKEDIT` 16 KB-aligned | yes | yes |
| exported `ghostty_*` | 102 | 173 |

So ITMS-90125/90209/90080 are cured upstream, and the claim below that no
post-processing tool can help is now true only of *injecting*
`LC_ENCRYPTION_INFO`. One defect remains: the asset is stamped `minos 17.0`
(Zig's `aarch64-ios` default) while Flutter hardcodes the wrapping framework's
`Info.plist` `MinimumOSVersion` to 13.0 → ITMS-90208. `scripts/build-ghostty-ios.sh`
now just downloads that asset and restamps `minos` with `vtool`, which needs no
Zig and no pinned runner SDK.

Keeping the committed override current is not cosmetic: it beats the release
download unconditionally, so a stale one silently pairs old exports with newer
bindings. `@Native` resolution is lazy even in AOT, so that surfaces as an
`ArgumentError` at the first call of each absent function — on device only, never
on simulator, macOS, or Android. The script's ABI check exists to catch it.

## Summary
TestFlight upload of build 3 was rejected. Three of the four errors are the
**same object**: `Runner.app/Frameworks/ghostty-vt.framework/ghostty-vt`. That
binary is the **Zig-built `ghostty-vt` dynamic library downloaded from upstream**
(`kingwill101/dart_terminal` release `ghostty_vte-v0.1.3`, tarball
`vte-ios-arm64.tar.gz`). Zig's self-hosted Mach-O linker does not produce an
App-Store-compliant dylib, so Apple rejects it.

## The rejections (all on ghostty-vt)
```
ITMS-90209  Invalid Segment Alignment — ghostty-vt.framework/ghostty-vt
ITMS-90125  LC_ENCRYPTION_INFO missing/invalid; "does not seem to have been
            built with Apple's linker"
ITMS-90080  (warning) not a Position Independent Executable (PIE)
```
`ITMS-90592` (export compliance) and `ITMS-90725` (SDK) are **unrelated** to
ghostty-vt — see the appendix; both are handled elsewhere.

## Why this happens (and why portable_pty is fine)
- **portable_pty** is Rust. Its CI build compiles from source with cargo →
  `clang` → Apple's `ld64`. ld64 stamps every Mach-O with `LC_ENCRYPTION_INFO`
  (cryptid 0), marks it PIE, and 16 KB-aligns segments. → passes validation.
- **ghostty-vt** is Zig. The upstream prebuilt (and any local `zig build`) links
  with Zig's **own** Mach-O linker, not `ld64`. That linker omits
  `LC_ENCRYPTION_INFO` (→ ITMS-90125), and the release binary isn't guaranteed
  PIE or page-aligned (→ 90080, 90209).

`LC_ENCRYPTION_INFO` is an `ld64`-only artifact. **No post-processing tool
(`vtool`, `install_name_tool`, re-`codesign`) can inject it.** So a
Zig-linked *dynamic framework* is a dead end for the App Store regardless of how
the alignment/PIE flags are set — the fix has to change *who does the final
link*, not tweak Zig flags.

## How the iOS binary is selected today
`packages/ghostty_vte/hook/build.dart`, in order:
1. `GHOSTTY_VTE_PREBUILT` env — unset in CI.
2. Local `.prebuilt/<label>/` — **`app/.prebuilt/` has only android + windows**,
   no `ios-arm64`, so skipped.
3. **Download** `assetHashes['ios-arm64']` from the GitHub release (build.dart
   L68-95). ← this is what ships today: the Zig dylib.
4. Build from source with `zig build -Demit-lib-vt=true` (L97-101, `_buildFromSource`
   L403+). **This does NOT help** — still Zig's linker, still no `LC_ENCRYPTION_INFO`.
   Do not waste time flipping `GHOSTTY_VTE_PREFER_SOURCE`.

Note ghostty-vt IS used on iOS (it's the VT parser that renders the terminal
view — unlike portable_pty, which iOS never calls). So the fix must keep the
symbols available to the app; it only changes linkage, not behaviour.

## Recommended fix — static-link ghostty-vt into Runner
Emit a **static archive** from Zig and expose it as a `StaticLinking` code asset.
Then Apple's `ld64` folds ghostty-vt into the `Runner` executable during the
Xcode archive. Runner is linked by ld64, so it gets `LC_ENCRYPTION_INFO`, PIE,
and alignment for free — and **there is no separate framework left to validate.**
Kills all three errors at once. This mirrors the standard resolution for
Rust/Zig/Go statics embedded in iOS apps.

Work required (verify each on the Mac):
1. **Zig side** — confirm Ghostty's `build.zig` can emit a static lib for
   `-Dtarget=aarch64-ios` (a `.a` from `-Demit-lib-vt`, or an equivalent step
   that produces `libghostty-vt.a`). If it only emits a dylib, add a static
   artifact in the vendored build or a post-`zig build` `libtool -static` over
   the emitted objects.
2. **Hook side** (`packages/ghostty_vte/hook/build.dart`):
   - Remove the `throw UnsupportedError` on `LinkModePreference.static` (L25-30).
   - `_addAsset` currently hardcodes `DynamicLoadingBundled()` (L142) — make it
     emit `StaticLinking()` with the `.a` when the preference is static.
   - Gate this to iOS device only; keep dynamic for desktop/simulator where it
     already passes.
3. **Link-mode preference** — ensure Flutter requests `static` for iOS device
   for this package. (portable_pty's `artifacts.dart` is the local precedent for
   honouring the per-target preference; ghostty needs the same shape.)
4. **Ship the artifact** — either build the `.a` from source in CI (add Zig +
   the iOS target to `deploy-ios.yml`), or drop a prebuilt
   `app/.prebuilt/ios-arm64/libghostty-vt.a` beside the committed
   `libghostty-vt.dylib` — that dylib is the precedent for beating a downloaded
   artifact this way. The hook's local `.prebuilt/` lookup (build.dart L59-66)
   runs before the download gate and works for any link mode.

### Fallback if static linking proves infeasible
Build the dylib's **objects** with Zig but do the **final link with `clang`/`ld64`**
(pass the objects to `clang -dynamiclib -target arm64-apple-ios`). That yields a
dylib carrying `LC_ENCRYPTION_INFO` + PIE. More fragile than static linking
(Zig runtime/symbol-visibility handoff), so treat as plan B.

## What to verify on the Mac
```bash
cd app && flutter build ipa --release --export-options-plist=<...>
FW=build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Frameworks
# After the fix there should be NO ghostty-vt.framework at all (static path):
ls "$FW"
# The three flags now live in the Runner binary — confirm ld64 stamped them:
BIN=build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Runner
otool -l "$BIN" | grep -A4 LC_ENCRYPTION_INFO   # present, cryptid 0
otool -hv "$BIN" | grep PIE                      # PIE flag set
# Dry-run App Store validation before burning a build number:
xcrun altool --validate-app -f build/ios/ipa/*.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```
Then confirm the terminal view still renders (ghostty-vt is exercised on-device,
not just load-linked).

## Relevant files
- `packages/ghostty_vte/hook/build.dart` — link-mode + artifact selection
  (static throw L25-30, `_addAsset` L137-146, download L68-95, source build L97-101 / L403+)
- `packages/ghostty_vte/lib/src/hook/asset_hashes.dart` — `releaseTag =
  'ghostty_vte-v0.1.3'`, `ios-arm64` → `vte-ios-arm64.tar.gz`
- `packages/portable_pty/lib/src/hook/artifacts.dart` — precedent for honouring
  the per-target link-mode preference
- `app/.prebuilt/ios-arm64/libghostty-vt.dylib` — the committed override that is
  the `.prebuilt/<label>/` precedent to mirror
- `.github/workflows/deploy-ios.yml` — add Zig + iOS target here if building the
  static lib on CI

## Appendix — the two non-ghostty rejections
- **ITMS-90725 (SDK 18.5 < 26)** — FIXED in `deploy-ios.yml`: runner moved
  `macos-15` → `macos-26` (Xcode 26 / iOS 26 SDK), with a `Verify iOS 26 SDK`
  guard step. Just needs the next CI run.
- **ITMS-90592 (export compliance mismatch)** — NOT a code bug. `Info.plist`
  already declares `ITSAppUsesNonExemptEncryption = true` (added 2026-06-30,
  commit 5c8a0c31), which is correct — the app uses X25519 + AES-256-GCM.
  The mismatch is that the app's **export-compliance documentation in App Store
  Connect** hasn't been completed to match that declaration. Fix in the web
  console: App Store Connect → the app → App Information / the build's Export
  Compliance → complete the encryption questionnaire (standard published
  algorithms, ENC exception self-classification). Optionally, once ASC issues a
  code, embed `ITSAppEncryptionExportComplianceCode` in `Info.plist` to skip the
  per-build prompt. No new binary is required *for this error alone*.
