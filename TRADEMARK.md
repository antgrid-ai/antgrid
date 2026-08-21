# Trademark policy

Antgrid's source code is licensed under the [Elastic License 2.0](LICENSE.md).
That licence covers copyright and patents. It does not grant any trademark
rights — it says so directly, under **Limitations** ("Any use of the licensor's
trademarks is subject to applicable law") and **No Other Rights** ("These terms
do not imply any licenses other than those expressly granted in these terms").

The two Apache-2.0 packages are no different: §6 of that licence excludes
trademarks just as explicitly, and their `NOTICE` files say so. This policy
applies to the whole project regardless of which licence a file falls under.

This file explains what that means in practice, so you do not have to guess.

## What is not licensed

- **The name "Antgrid"**, alone or as part of another name.
- **The logo, monogram and wordmark.** Sources live in `app/assets/logo/` and
  `app/assets/icon/`, are mirrored at `site/public/logo/` and `web/public/logo/`,
  and are compiled into the per-platform icon sets under
  `app/android/app/src/main/res/mipmap-*/`,
  `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/`,
  `app/macos/Runner/Assets.xcassets/AppIcon.appiconset/`,
  `app/windows/runner/resources/app_icon.ico` and `app/web/icons/`.
- **The application identifiers**, listed in the rebranding table below.

These remain the property of Bharath Mohan (trading as Radha AI Products),
whether or not they are registered in your jurisdiction.

## What you may do without asking

- **Redistribute unmodified copies** of the software under the Antgrid name and
  marks. An unmodified copy is Antgrid, so calling it Antgrid is accurate.
- **Refer to the project by name in truthful, descriptive statements** — "compatible
  with Antgrid", "a fork of Antgrid", "an Antgrid bridge implementation",
  "imports Antgrid session logs". Use the name to say what your thing does, not
  as the name of your thing.
- **Use screenshots** of the app in articles, reviews, comparisons, documentation
  and talks.

None of this requires permission, and none of it needs to be cleared with us
first.

## Forks that distribute binaries must rebrand

If you modify the software and distribute the result — a published build, an app
store listing, a hosted download, an installer — it must not present itself as
Antgrid. Give it a different name, a different icon, and different application
identifiers. Otherwise users cannot tell your build from ours, and neither can we
when they report a bug.

Every identifier below is currently set to an Antgrid value and must be changed:

| Identifier | Current value | Defined in |
|---|---|---|
| Android `applicationId` and `namespace` | `ai.radhaai.antgrid` | `app/android/app/build.gradle.kts` |
| iOS bundle identifier, plus the identifiers derived from it: the `ai.radhaai.antgrid.NotificationService` extension and the `ai.radhaai.antgrid.push` keychain access group | `ai.radhaai.antgrid` | `app/ios/Runner.xcodeproj/project.pbxproj`, `app/ios/NotificationService/` |
| macOS bundle identifier | `ai.radhaai.antgrid` | `app/macos/Runner/Configs/AppInfo.xcconfig` |
| Linux `APPLICATION_ID` | `ai.radhaai.antgrid` | `app/linux/CMakeLists.txt` |
| MSIX `identity_name` / `publisher_display_name` | `RadhaAIProduct.antgrid` / `Radha AI Product` | `app/pubspec.yaml` (`msix_config`) |
| Custom URL scheme | `antgrid://` | `app/ios/Runner/Info.plist`, `app/macos/Runner/Info.plist`, `app/android/app/src/main/AndroidManifest.xml`, `protocol_activation` in `app/pubspec.yaml` |
| User-visible application name | `antgrid` | `android:label` in `app/android/app/src/main/AndroidManifest.xml`, `display_name` in `app/pubspec.yaml`, `BINARY_NAME` in `app/linux/CMakeLists.txt`, `project()` and `BINARY_NAME` in `app/windows/CMakeLists.txt` (these name the executable `antgrid.exe`), the window title and single-instance token in `app/windows/runner/main.cpp`, `PRODUCT_NAME` in `app/macos/Runner/Configs/AppInfo.xcconfig` |
| Publisher strings compiled into the shipped desktop binaries | `Radha AI Products`, `antgrid`, `antgrid.exe`, `Copyright (C) 2026 Radha AI Products. All rights reserved.` | `CompanyName`, `ProductName`, `FileDescription`, `InternalName`, `OriginalFilename` and `LegalCopyright` in `app/windows/runner/Runner.rc`; `PRODUCT_COPYRIGHT` in `app/macos/Runner/Configs/AppInfo.xcconfig` |

That last row is the one most easily missed, because nothing in the build warns
you about it. A Windows executable carries those strings in its version resource,
where the OS surfaces them in the file's Properties dialog and in installer and
SmartScreen prompts. A fork that renames everything else but leaves them alone
ships a binary that tells the user it was published by Radha AI Products — worse
than a name collision, because it is an affirmative claim of origin.

These publisher strings identify **who distributed that binary**, which is why a
fork must set its own. They are not the copyright notices ELv2 protects. That
distinction matters: rebranding means replacing the marks that identify the
product to users, and it does **not** mean stripping the licence. ELv2 separately
requires you to keep the licensing and copyright notices intact, to pass these
terms on to anyone who gets a copy from you, and to state prominently that you
modified the software. Change the name, the icon and the publisher metadata;
leave `LICENSE.md` and the source copyright headers alone.

## What needs permission

- Using the Antgrid name or logo as the name, icon or branding of your product,
  service or company.
- Any use that suggests your project is official, endorsed by, or affiliated with
  Antgrid when it is not.
- Domain names, app store listings, package names or social accounts that a
  reasonable person would read as the official Antgrid.
- Merchandise carrying the marks.

## Asking

Open a thread in [GitHub Discussions on `antgrid-ai/antgrid`](https://github.com/antgrid-ai/antgrid/discussions)
describing what you want to do. Most requests are fine; we mainly want to avoid
two different things being called Antgrid.

If we ask you to stop a use that falls outside this policy, we will say what
specifically is a problem and give you a reasonable period to change it.
