# macOS updater completion patch

Vendored from `auto_updater_macos` 1.0.0, published by
[leanflutter/auto_updater](https://github.com/leanflutter/auto_updater).
The upstream MIT licence is retained in `LICENSE`.

The `antgrid/sparkle_update_cycle` method channel forwards Sparkle's
[`updater(_:didFinishUpdateCycleFor:error:)`](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
delegate callback as `finished`. Sparkle calls it when an update is dismissed
or skipped, as well as when a cycle ends with an error. Upstream returns immediately at
launch and does not forward normal completion; that leaves the Dart service
busy after Remind Me Later or Skip This Version.

Checks keep their upstream launch-time reply so existing installation handoff
bookkeeping still happens before relaunch. Requests are refused when Sparkle
cannot start a check. Existing events and the app-facing Dart updater package
are unchanged. The app's dependency override selects this native
implementation on macOS only.

Remove the override once upstream provides cycle completion and adapt
`MacosSparkleUpdateService.startUpdate` to its completion API. The Dart
regression suite is `app/test/update/macos_sparkle_update_service_test.dart`;
native Sparkle UI smoke checks require a macOS release build.
