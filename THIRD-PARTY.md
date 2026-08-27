# Third-party software

Antgrid is distributed mainly under the Elastic License 2.0 (see
[`LICENSE.md`](LICENSE.md)), a source-available licence rather than an OSI-approved
open source one, with two of its own packages under Apache-2.0
([`LICENSING.md`](LICENSING.md) maps which licence covers what). This file records
the licences of the third-party software Antgrid vendors, bundles, links against or
otherwise redistributes.

## Scope

This file lists **direct** dependencies, plus anything whose compiled output ends
up inside a shipped artefact. The transitive dependency tree is **not** enumerated
here — it is too large to maintain by hand and it changes on every lockfile update.
It was, however, scanned in bulk for copyleft and non-permissive terms, and the
result of that scan is the first section below.

Two transitive packages appear by name anyway, because they are copyleft and they
ship: `gtk` and `dbus`.

Versions are as resolved when this file was written. The lockfiles are the source
of truth:

| Layer | Source of truth |
|---|---|
| Flutter / Dart | `app/pubspec.yaml`, `app/pubspec.lock`, `packages/*/pubspec.yaml` |
| TypeScript | `package.json` and each workspace's `package.json`, `bun.lock` |
| Rust (inside `portable_pty`) | `pkgs/pty/portable_pty/rust/Cargo.toml` and `Cargo.lock` in the fork, at the ref `app/pubspec.yaml` pins |
| Bundled assets | the `flutter:` section of `app/pubspec.yaml`, `app/assets/` |
| Tracked native artefacts | `app/.prebuilt/` |

---

## Copyleft and non-permissive licences

### No GPL, LGPL, AGPL or SSPL code ships in an Antgrid build

Not in the Flutter app, not in the bridge binary, not in the relay, not in the web
service.

Scan basis: all 222 packages resolved by `app/pubspec.lock`. The 210 hosted ones
were checked against their licence files in the local pub cache. The remaining
twelve have no pub-cache entry to read and were checked at their source instead:
seven come from the Flutter SDK, four are the git-pinned forks (all MIT — the
`push` fork plus the three `dart_terminal` packages, covered under "Forked
source"), and one is `antgrid_relay_client`, which is first-party and resolved by
path. On the TypeScript side, every `package.json` in the
installed dependency trees of the Bun workspaces and of `site/`.

Exactly one LGPL component exists anywhere in the tree, and it does not ship:

| Package | Version | Licence | Reached via | Ships? |
|---|---|---|---|---|
| `@img/sharp-win32-x64` | 0.34.5 | `Apache-2.0 AND LGPL-3.0-or-later` | `site/` — the Astro image pipeline | No. Build-time image processing for the static marketing site. |

`sharp` itself is Apache-2.0; the LGPL component is the platform-specific prebuilt
binary. `site/` is not one of the root Bun workspaces and produces a static site, so
this is never linked into the bridge, relay, app or web service.

### MPL-2.0 — two packages ship, one does not

MPL-2.0 is file-level copyleft. It permits distribution inside a larger proprietary
or source-available work provided the MPL-licensed files stay under MPL and their
source remains available. Antgrid does not modify any of these, so attribution plus
a pointer to upstream is the whole obligation. None of them conflicts with ELv2.

| Package | Version | Reached via | Ships? |
|---|---|---|---|
| `gtk` | 2.2.0 | `app_links` → `app_links_linux` → `gtk` | Yes, in Linux desktop builds |
| `dbus` | 0.7.14 | `flutter_local_notifications` → `flutter_local_notifications_linux` → `dbus` | Yes, in Linux desktop builds |
| `lightningcss` | 1.32.0 | `@tailwindcss/vite` → `@tailwindcss/node` → `lightningcss`, in `web/` and `site/` | No. Build-time CSS compiler; its output carries no MPL obligation. |

### Proprietary — one package, and it is redistributed

`@anthropic-ai/claude-agent-sdk` is not open source and grants no redistribution
right in its licence text. Antgrid uses it to drive Claude Code sessions
(`bridge/src/agents/claude-code/`), and `bridge/package.json`'s build script runs
`bun build src/index.ts --compile …`, so it is compiled into the bridge binary that
ships to users.

| Field | Value |
|---|---|
| Package | `@anthropic-ai/claude-agent-sdk` 0.3.201, and the platform package `@anthropic-ai/claude-agent-sdk-win32-x64` 0.3.201 |
| `license` field | `SEE LICENSE IN README.md` |
| `LICENSE.md`, in full | `© Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance.` |

Whether a given redistribution is permitted is governed entirely by Anthropic's
linked legal agreements, not by anything readable in the package. If you fork
Antgrid and distribute your own bridge binary, that question is yours to answer.

### Everything else is permissive

Every other dependency, direct and transitive, resolved to MIT, BSD-2-Clause,
BSD-3-Clause, ISC, Apache-2.0, 0BSD, Unlicense, SIL OFL 1.1, CC BY 4.0 or CC0 1.0.
None restricts distribution under ELv2. The attribution obligations that do apply —
MIT, BSD, Apache-2.0, OFL and CC BY — are what the rest of this file discharges.

---

## Forked source

These matter most: what builds is not the upstream release, so the modified work
and its licence and copyright notices have to be named explicitly.

### Terminal engine and PTY — forks resolved from git

Three Dart packages from the `kingwill101/dart_terminal` monorepo are not taken
from pub.dev. They are pinned to a commit on `antgrid-ai/dart_terminal` — a fork
Antgrid owns — in `app/pubspec.yaml`'s `dependency_overrides`, so the fork, not
the pub.dev release, is what builds:

```yaml
ghostty_vte:
  git:
    url: https://github.com/antgrid-ai/dart_terminal.git
    path: pkgs/vte/ghostty_vte
    ref: 614e05d9e1f927ef9a64d34cde67e094e56659c0
```

`ghostty_vte_flutter` and `portable_pty` are pinned to the same repository and
ref, at `pkgs/vte/ghostty_vte_flutter` and `pkgs/pty/portable_pty`.

The ref above must match `app/pubspec.yaml`. Nothing checks the pairing, and
this file is only read under audit pressure — so a stale ref here names a tree
that was never distributed and no one finds out until it matters.

| Package | Version | Licence | Copyright holder | Upstream |
|---|---|---|---|---|
| `ghostty_vte` | 0.1.4+antgrid.1 | MIT | Copyright (c) 2026 kingwill101 | `https://github.com/kingwill101/dart_terminal/tree/master/pkgs/vte/ghostty_vte` |
| `ghostty_vte_flutter` | 0.1.4+antgrid.1 | MIT | Copyright (c) 2026 kingwill101 | `https://github.com/kingwill101/dart_terminal/tree/master/pkgs/vte/ghostty_vte_flutter` |
| `portable_pty` | 0.0.6+antgrid.2 | MIT | Copyright (c) 2026 kingwill101 | `https://github.com/kingwill101/dart_terminal/tree/master/pkgs/pty/portable_pty` |

The MIT texts are not redistributed in this repository — each package carries its
upstream `LICENSE` in the fork, and pub resolves it into the pub cache alongside
the source. Owning the fork repository does not make this Antgrid's code: the
copyright above is upstream's and stays, and the fork is MIT throughout, so no
part of it may take on Antgrid's ELv2 terms (`LICENSING.md`).

Why the fork exists: an FFI fix for terminal colours, the `showFocusRing` /
`showKeyboardOnInteraction` / `GhosttyTerminalSoftKeyboardController` host hooks
the app's terminal view needs, Android PTY libraries relinked to pass Play's
16 KB page-alignment gate, and iOS PTY binaries published as dylibs rather than
static archives, which is the only link mode Flutter's iOS native-assets driver
accepts. `portable_pty`'s prebuilt binaries are published from the fork for those
last two reasons; `ghostty_vte`'s are byte-identical to upstream's and still come
from `kingwill101/dart_terminal`. What diverges, and what going back would take,
is tracked in
[`docs/dart-terminal-fork-release.md`](docs/dart-terminal-fork-release.md).

### Fork resolved from git

`push` is pinned to a commit on a fork repository in `app/pubspec.yaml`:

```yaml
push:
  git:
    url: https://github.com/bharathm03/push.git
    ref: bf4f22f0c2763416265a02268e3b071ab1767885
```

| Field | Value |
|---|---|
| Package / version | `push` 3.3.3 |
| Licence | MIT |
| Copyright holder | Copyright © 2022 Ben Butterworth |
| Upstream, per the package's own `pubspec.yaml` | `https://github.com/ben-xD/push` |

The fork adds a single commit — an AndroidManifest-configurable background Dart
entrypoint. Stock `push` runs the host app's `main()` headlessly when a push
arrives in the terminated state; the fork lets Antgrid run a dedicated background
entrypoint instead. Upstream is dormant, so the fork is expected to be permanent.

Note that `app/pubspec.yaml` refers to the upstream as `uxduck/push` while the
package's own metadata records `ben-xD/push` (its `homepage` is `tlduck.com`).
These appear to be the same project under a renamed account. Attribution follows
the `LICENSE` file, which names Ben Butterworth.

### First-party packages

Two are Apache-2.0 and carry their own `LICENSE` and `NOTICE`; the third is
covered by [`LICENSE.md`](LICENSE.md). [`LICENSING.md`](LICENSING.md) is the full
map and explains why.

| Package | Language | Licence | Role |
|---|---|---|---|
| `packages/antgrid-wire` | TypeScript | Apache-2.0 | Shared route-frame codec and relay control-envelope schemas |
| `packages/antgrid_relay_client` | Dart | Apache-2.0 | Pure Dart relay and crypto client |
| `packages/antgrid_eval_client` | Dart | Elastic-2.0 | CLI wrapper around the above, for end-to-end evals |

`antgrid_eval_client` depends on `antgrid_relay_client`, and `bridge/` and
`relay/` depend on `antgrid-wire`. Apache-2.0 code may be combined into an
ELv2-licensed work, so that direction is fine; the reverse is not. **Never move
code from an ELv2 component into either Apache package** — that relicenses it
permissively and cannot be undone once published.

---

## Bundled binary assets and native code

### Fonts

`app/assets/fonts/` holds six weights of **JetBrains Mono NL** — the no-ligatures
build, because the ligature build forms combined glyphs across terminal cells.

| Field | Value |
|---|---|
| Family | JetBrains Mono NL |
| Licence | SIL Open Font License, Version 1.1 |
| Copyright | Copyright 2020 The JetBrains Mono Project Authors (`https://github.com/JetBrains/JetBrainsMono`) |
| Licence text | `app/assets/fonts/OFL.txt` |

OFL 1.1 requires the licence to travel with the font. Antgrid satisfies that twice,
and **both must be preserved**: `OFL.txt` is declared as a Flutter asset in
`app/pubspec.yaml`, and `app/lib/main.dart` registers it with Flutter's
`LicenseRegistry` so it is reachable from the standard Flutter licence listing.
Pruning `OFL.txt` as an apparently unused asset would put the app out of
compliance.

This is the only bundled font. UI chrome uses the platform system sans-serif.

### Ghostty (`libghostty-vt`) — modified

The terminal engine behind `ghostty_vte` is a separate upstream project. One
compiled artefact is **tracked in git**: `app/.prebuilt/ios-arm64/libghostty-vt.dylib`.
The web build's `ghostty-vt.wasm` ships as an asset inside the resolved
`ghostty_vte_flutter` package. On every other platform `ghostty_vte`'s build hook
downloads a released library, or compiles Ghostty from source if no download can
be satisfied.

| Field | Value |
|---|---|
| Project | Ghostty, `https://github.com/ghostty-org/ghostty` |
| Licence | MIT |
| Copyright holder | Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors |
| Pinned commit for the released libraries | `4d605bf0d819df901a0332bbb320dc849fdd82e4` (`native_prebuilt.yaml` in the fork) |
| Pinned commit for the iOS prebuilt | the same — `app/.prebuilt/ios-arm64/libghostty-vt.dylib` is the upstream `ghostty_vte-v0.1.4` device asset with its `minos` restamped (`scripts/build-ghostty-ios.sh`) |

**The shipped library is a modified work.** On Android, `ghostty_vte`'s build
recipe applies `ghostty-libvt-link-libc.patch` to Ghostty source before
compilation.
The patch adds a single `lib.linkLibC()` call in `src/build/GhosttyLibVt.zig` so the
shared object carries its libc dependency explicitly rather than leaving symbols
such as `getauxval` unresolved at `dlopen` time on Android. Nothing else in Ghostty
is changed. On iOS device the committed dylib is upstream's own build with one
Mach-O metadata field rewritten (`minos`, via `vtool`); no code is altered.

### PDFium

PDF viewing in the app goes through `pdfrx`, which resolves PDFium as a native
runtime library via `pdfium_dart` / `pdfium_flutter`. The binaries are downloaded
from the `bblanchon/pdfium-binaries` releases at `chromium/7811`
(`pdfium_dart`'s `hook/build.dart`); on iOS and macOS PDFium arrives as the
`pdfium_flutter` XCFramework instead.

| Field | Value |
|---|---|
| Project | PDFium, `https://pdfium.googlesource.com/pdfium/` |
| Licence | BSD-3-Clause |
| Copyright holder | Copyright 2014 The PDFium Authors |

Verified against `https://pdfium.googlesource.com/pdfium/+/refs/heads/main/LICENSE`,
not against a file in this repository — PDFium's licence text is not vendored here.
PDFium also bundles third-party components carrying their own notices; if you
redistribute PDFium binaries yourself, take those from upstream.

### `bun-pty` native libraries

The bridge's PTY layer is `bun-pty`, which publishes prebuilt Rust shared libraries
inside the npm package (`librust_pty.so`, `librust_pty_arm64.so`,
`librust_pty.dylib`, `librust_pty_arm64.dylib`, `rust_pty.dll`). `bun build --compile`
puts them in the shipped bridge binary.

| Field | Value |
|---|---|
| Package | `bun-pty` 0.4.8 |
| Licence | MIT |
| Copyright holder | Copyright (c) 2025 Dilip Thapa |

### Rust crates inside `portable_pty`

`portable_pty` ships `libportable_pty_rs`, which is linked into desktop and mobile
builds, as a prebuilt binary. Its Rust source lives at `pkgs/pty/portable_pty/rust/`
in the fork, at the ref `app/pubspec.yaml` pins; `Cargo.toml` and `Cargo.lock`
there declare:

| Crate | Version | Role |
|---|---|---|
| `portable-pty` | 0.9.0 | `forkpty`/`openpty` on Unix, ConPTY on Windows |
| `libc` | 0.2.182 | POSIX bindings |
| `cbindgen` | 0.28.0 | build-dependency, C header generation |

Only `libc` could be verified locally, and it is dual-licensed MIT OR Apache-2.0
(both texts ship in the crate). `portable-pty` and `cbindgen` are absent from this
machine's Cargo cache because this Rust library has not been built here, so their
licence texts are not reproduced: take them from the crates themselves, along with
the transitive tree in the fork's `Cargo.lock`, on a machine that
has run the build.

`cbindgen` is a `[build-dependencies]` entry — a host tool that generates a C
header at build time. Its code is not linked into `libportable_pty_rs`, so
whatever its licence turns out to be, it carries no distribution obligation for a
shipped Antgrid build.

### Icon artwork

`app/lib/design/ab_icons.dart` draws the app's icons from two Iconify collections
shipped inside `iconify_flutter` 0.0.7 (itself MIT, Copyright (c) 2022 Andrew
Nasef). **That MIT covers the package, not the artwork.** The collections carry
their own terms:

| Collection | Imported as | Author | Licence |
|---|---|---|---|
| Codicons | `package:iconify_flutter/icons/codicon.dart` | Microsoft Corporation | CC BY 4.0 |
| Material Design Icons | `package:iconify_flutter/icons/mdi.dart` | Pictogrammers | Apache 2.0 |

Codicons is the primary icon set for the whole app UI. Material Design Icons
supplies three glyphs Codicons does not provide: the diagonal expand/collapse pair
and the attachment paperclip.
**CC BY 4.0 requires attribution**, which is what the table above provides — keep it
intact in any redistribution. Licences taken from the Iconify collections list
(`https://github.com/iconify/icon-sets/blob/master/collections.md`), which
`iconify_flutter`'s own README points at for exactly this reason.

`app/lib/design/ab_agent_marks.dart` inlines single-path SVG brand marks for the
coding agents the bridge can launch, sourced from **Simple Icons** (Simple Icons
Collaborators, CC0 1.0). CC0 waives copyright and imposes no attribution
requirement. It does **not** waive trademark: these are third-party company and
product logos and remain the marks of their owners. See [`TRADEMARK.md`](TRADEMARK.md).

### Flutter SDK and engine

The Flutter SDK is a build prerequisite rather than something vendored here, but its
engine ships inside every build. The SDK is BSD-3-Clause, Copyright 2014 The Flutter
Authors. The engine's own third-party licence bundle travels with the SDK as
`bin/cache/pkg/sky_engine/LICENSE` and is surfaced through Flutter's
`LicenseRegistry` alongside the font entry described above.

### Antgrid's own artwork

`app/assets/logo/` and `app/assets/icon/` hold the Antgrid mark, wordmark and
platform icons. They are first-party and covered by [`LICENSE.md`](LICENSE.md) as
copyrighted material — but ELv2 grants no trademark rights, so redistributing them
is governed by [`TRADEMARK.md`](TRADEMARK.md), not by this file.

---

## Direct runtime dependencies

Direct dependencies only. Transitive dependencies are not enumerated — see
[Scope](#scope).

### `app/` — Flutter and Dart

Declared in `app/pubspec.yaml`, versions resolved by `app/pubspec.lock`. Licence and
copyright holder read from each package's own licence file.

| Package | Version | Licence | Copyright holder |
|---|---|---|---|
| `app_links` | 7.2.0 | Apache-2.0 | not stated in `LICENSE`; upstream `github.com/llfbandit/app_links` |
| `auto_updater` | 1.0.0 | MIT | Copyright (c) 2022-2024 LiJianying |
| `collection` | 1.19.1 | BSD-3-Clause | Copyright 2015, the Dart project authors |
| `crypto` | 3.0.7 | BSD-3-Clause | Copyright 2015, the Dart project authors |
| `cryptography` | 2.9.0 | Apache-2.0 | not stated in `LICENSE`; upstream `github.com/dint-dev/cryptography` |
| `cryptography_flutter` | 2.3.4 | Apache-2.0 | not stated in `LICENSE`; upstream `github.com/dint-dev/cryptography` |
| `device_info_plus` | 11.5.0 | BSD-3-Clause | Copyright 2017 The Chromium Authors |
| `file_selector` | 1.1.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `fleather` | 1.27.0 | MIT **and** BSD-3-Clause | Copyright (c) 2023 Fleather; Copyright 2018, the Zefyr project authors |
| `flutter_colorpicker` | 1.1.0 | MIT | Copyright (c) 2021 fuyumi |
| `flutter_local_notifications` | 22.0.1 | BSD-3-Clause | Copyright 2018 Michael Bui |
| `flutter_riverpod` | 3.3.2 | MIT | Copyright (c) 2020 Remi Rousselet |
| `flutter_secure_storage` | 10.3.1 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `flutter_svg` | 2.2.4 | MIT | Copyright (c) 2018 Dan Field |
| `ghostty_vte_flutter` | 0.1.4+antgrid.1 | MIT | Copyright (c) 2026 kingwill101 — fork resolved from git, see above |
| `http` | 1.6.0 | BSD-3-Clause | Copyright 2014, the Dart project authors |
| `iconify_flutter` | 0.0.7 | MIT | Copyright (c) 2022 Andrew Nasef — icon artwork is separately licensed, see above |
| `in_app_update` | 4.2.5 | MIT | Copyright (c) 2020 Victor Choueiri |
| `markdown` | 7.3.1 | BSD-3-Clause | Copyright 2012, the Dart project authors |
| `markdown_widget` | 2.3.2+8 | MIT | Copyright (c) 2020 android-bro |
| `package_info_plus` | 9.0.1 | BSD-3-Clause | Copyright 2017 The Chromium Authors |
| `parchment` | 1.27.0 | MIT **and** BSD-3-Clause | Copyright (c) 2023 Fleather; Copyright 2018, the Zefyr project authors |
| `path` | 1.9.1 | BSD-3-Clause | Copyright 2014, the Dart project authors |
| `path_provider` | 2.1.5 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `pdfrx` | 2.4.4 | MIT | Copyright (c) 2018 @espresso3389 (Takashi Kawasaki) — pulls PDFium, see above |
| `pub_semver` | 2.2.0 | BSD-3-Clause | Copyright 2014, the Dart project authors |
| `push` | 3.3.3 | MIT | Copyright © 2022 Ben Butterworth — git-pinned fork, see above |
| `re_editor` | 0.9.0 | MIT | Copyright (c) 2024 Reqable |
| `re_highlight` | 0.0.3 | MIT | Copyright (c) 2024 Reqable |
| `sentry_flutter` | 9.22.0 | MIT | Copyright (c) 2019 Sentry |
| `shared_preferences` | 2.5.5 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `shelf` | 1.4.2 | BSD-3-Clause | Copyright 2014, the Dart project authors |
| `shelf_web_socket` | 3.0.0 | BSD-3-Clause | Copyright 2014, the Dart project authors |
| `super_clipboard` | 0.9.0 | MIT | Copyright (c) 2022 Superlist, Matej Knopp and the contributors |
| `url_launcher` | 6.3.2 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `uuid` | 4.5.3 | MIT | Copyright (c) 2021 Yulian Kuncheff |
| `web_socket_channel` | 3.0.3 | BSD-3-Clause | Copyright 2016, the Dart project authors |
| `webview_all` | 1.3.5 | MIT | Copyright 2021-2026 Abandoft (`github.com/abandoft`) |
| `window_manager` | 0.5.2 | MIT | Copyright (c) 2022-present LiJianying |
| `xml` | 6.6.1 | MIT | Copyright (c) 2006-2025 Lukas Renggli |

`antgrid_relay_client` is also a direct dependency; it is first-party.

### `bridge/` — `antgrid-bridge`

The bridge ships as a compiled binary, so every runtime dependency here is
redistributed inside it.

| Package | Version | Licence | Copyright holder |
|---|---|---|---|
| `@anthropic-ai/claude-agent-sdk` | 0.3.201 | proprietary — see above | Anthropic PBC |
| `@inquirer/prompts` | 8.4.2 | MIT | Copyright (c) 2025 Simon Boudrias |
| `@opencode-ai/sdk` | 1.15.10 | MIT | declared in `package.json`; the published package ships no licence file |
| `bun-pty` | 0.4.8 | MIT | Copyright (c) 2025 Dilip Thapa |
| `chokidar` | 5.0.0 | MIT | Copyright (c) 2012 Paul Miller, Elan Shanker |
| `commander` | 13.1.0 | MIT | Copyright (c) 2011 TJ Holowaychuk |
| `ignore` | 7.0.5 | MIT | Copyright (c) 2013 Kael Zhang, contributors |
| `pino` | 9.7.0 | MIT | Copyright (c) 2016-2024 Matteo Collina, David Mark Clements and the Pino contributors |
| `yaml` | 2.8.3 | ISC | Copyright Eemeli Aro |
| `zod` | 4.4.1 | MIT | Copyright (c) 2025 Colin McDonnell |

`antgrid-wire` is also a dependency; it is first-party.

### `relay/` — `antgrid-relay`

| Package | Version | Licence | Copyright holder |
|---|---|---|---|
| `jose` | 6.2.3 | MIT | Copyright (c) 2018 Filip Skokan |
| `zod` | 4.4.1 | MIT | Copyright (c) 2025 Colin McDonnell |

`antgrid-wire` is also a dependency; it is first-party.

### `web/` — `antgrid-web`

Runs as a server; not distributed to users as a binary. `htmx.org` is the exception —
it is declared as a dev dependency but bundled by Vite and served to browsers. 0BSD
imposes no attribution requirement, but it is listed here for completeness.

| Package | Version | Licence | Copyright holder |
|---|---|---|---|
| `@better-auth/core` | 1.6.9 | MIT | Copyright (c) 2024 - present, Bereket Engida |
| `@better-auth/oauth-provider` | 1.6.11 | MIT | Copyright (c) 2024 - present, Bereket Engida |
| `@better-auth/prisma-adapter` | 1.6.9 | MIT | Copyright (c) 2024 - present, Bereket Engida |
| `@noble/ed25519` | 2.3.0 | MIT | Copyright (c) 2019 Paul Miller |
| `@noble/hashes` | 1.8.0 | MIT | Copyright (c) 2022 Paul Miller |
| `@paddle/paddle-js` | 1.6.4 | Apache-2.0 | not stated in `LICENSE` |
| `@paddle/paddle-node-sdk` | 3.8.0 | Apache-2.0 | not stated in `LICENSE` |
| `@prisma/adapter-pg` | 6.19.3 | Apache-2.0 | not stated in `LICENSE` |
| `@prisma/client` | 6.19.3 | Apache-2.0 | not stated in `LICENSE` |
| `better-auth` | 1.6.9 | MIT | Copyright (c) 2024 - present, Bereket Engida |
| `dotenv` | 17.4.2 | BSD-2-Clause | Copyright (c) 2015, Scott Motte |
| `hono` | 4.12.15 | MIT | Copyright (c) 2021 - present, Yusuke Wada and Hono contributors |
| `htmx.org` | 2.0.4 | 0BSD | no copyright line in `LICENSE` |
| `jose` | 6.2.3 | MIT | Copyright (c) 2018 Filip Skokan |
| `pg` | 8.20.0 | MIT | Copyright (c) 2010 - 2021 Brian Carlson |
| `postgres` | 3.4.9 | Unlicense | declared in `package.json`; no licence file shipped |
| `razorpay` | 2.9.6 | MIT | declared in `package.json`; no licence file shipped |
| `zod` | 4.4.1 | MIT | Copyright (c) 2025 Colin McDonnell |

`antgrid-wire` is also a dependency; it is first-party.

### `packages/antgrid-wire`, `bridge/plugin`, `evals/`

| Workspace | Package | Version | Licence | Copyright holder |
|---|---|---|---|---|
| `packages/antgrid-wire` | `zod` | 4.4.1 | MIT | Copyright (c) 2025 Colin McDonnell |
| `bridge/plugin` | `@modelcontextprotocol/sdk` | 1.29.0 | MIT | Copyright (c) 2024 Anthropic, PBC |
| `evals/` | `antgrid-wire` | workspace | ELv2 | first-party |

---

## Build and development tooling

None of this is distributed in an Antgrid artefact.

### `app/` dev dependencies

| Package | Version | Licence | Copyright holder |
|---|---|---|---|
| `fake_async` | 1.3.3 | Apache-2.0 | not stated in `LICENSE`; upstream `github.com/dart-lang/test/tree/master/pkgs/fake_async` |
| `flutter_launcher_icons` | 0.14.4 | MIT | Copyright (c) 2019 Mark O'Sullivan |
| `flutter_lints` | 6.0.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `flutter_native_splash` | 2.4.7 | MIT | Copyright (c) 2022 Jon Hanson |
| `flutter_secure_storage_platform_interface` | 2.0.1 | BSD-3-Clause | Copyright 2017 German Saprykin |
| `msix` | 3.18.0 | MIT | Copyright (c) 2022 Yehuda Kremer |
| `shared_preferences_platform_interface` | 2.4.2 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| `visibility_detector` | 0.4.0+2 | BSD-3-Clause | Copyright 2018 the Dart project authors |

`flutter_test` and `flutter_driver` come from the Flutter SDK.

### TypeScript workspace dev dependencies

`@types/bun` 1.3.13 (MIT, Copyright (c) Microsoft Corporation) and `typescript`
5.9.3 (Apache-2.0) are shared by `bridge/`, `relay/`, `web/`, `evals/` and
`packages/antgrid-wire`.

- `bridge/` — `pino-pretty` 13.1.3 (MIT, Copyright (c) 2019 the Pino team)
- `web/` — `@better-auth/cli` 1.4.21 (MIT), `@tailwindcss/vite` 4.2.4 (MIT,
  Copyright (c) Tailwind Labs, Inc.), `@types/pg` 8.20.0 (MIT), `concurrently` 9.2.1
  (MIT, Copyright (c) 2015 Kimmo Brunfeldt), `daisyui` 5.5.19 (MIT, Copyright (c)
  2020 Pouya Saadeghi), `prisma` 6.19.3 (Apache-2.0), `tailwindcss` 4.2.4 (MIT),
  `typed-htmx` 0.3.1 (ISC, Copyright (c) 2023 Viet Dinh), `vite` 6.4.2 (MIT,
  Copyright (c) 2019-present, VoidZero Inc. and Vite contributors)
- repository root — `jscpd` 5.0.9 (MIT, declared in `package.json`; no licence file
  shipped)

### `site/` — the marketing site

Not a root Bun workspace; builds a static site.

| Package | Version | Licence | Copyright holder |
|---|---|---|---|
| `@astrojs/sitemap` | 3.7.3 | MIT | Copyright (c) 2021 Fred K. Schott |
| `@iconify-json/tabler` | 1.2.35 | MIT | declared in `package.json`; no licence file shipped |
| `astro` | 5.18.2 | MIT | Copyright (c) 2021 Fred K. Schott |
| `astro-icon` | 1.1.5 | MIT | Copyright (c) 2021 Nate Moore |
| `@astrojs/check` | 0.9.9 | MIT | Copyright (c) 2021 Fred K. Schott |
| `@playwright/test` | 1.61.0 | Apache-2.0 | not stated in `LICENSE` |
| `@tailwindcss/vite`, `tailwindcss` | 4.3.1 | MIT | Copyright (c) Tailwind Labs, Inc. |

`sharp` 0.34.5 (Apache-2.0) reaches this tree through Astro's image pipeline; its
Windows platform binary is the one LGPL component in the repository, covered above.

### `aspire/` — local stack orchestration

Outside the root `workspaces` array, so a root `bun install` does not reach it and
its dependency tree was not installed when this file was written. It is a Bun
project like the rest — `aspire/bun.lock` is committed, so the resolved set is
auditable from a fresh checkout without installing anything. `aspire/package.json`
declares
`vscode-jsonrpc` ^8.2.0 as its only runtime dependency, plus `@types/node`, `eslint`,
`nodemon`, `tsx`, `typescript` and `typescript-eslint` for development.

---

## Keeping this file current

Update it in the same change that adds, removes or re-pins a direct dependency, a
fork, a bundled asset or a native artefact. Two things in particular are
easy to break silently:

- **`OFL.txt` must stay a declared Flutter asset and stay registered with
  `LicenseRegistry`.** Removing either breaks OFL 1.1 compliance.
- **A `dependency_overrides` entry or a git-pinned `ref` makes a package a fork.**
  A licence audit that reads pub.dev metadata alone will not notice, because
  `pubspec.lock` records these with `source: path` or `source: git`.
